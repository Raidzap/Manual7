#import <Foundation/Foundation.h>
#import "../iOS/M7VideoRecorder.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSURL *url = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:[NSString stringWithFormat:@"M7-%@.mov", NSUUID.UUID.UUIDString]];
        M7VideoRecorder *recorder = [[M7VideoRecorder alloc] initWithOutputURL:url];
        NSDictionary *before = recorder.snapshot;
        assert(![before[@"started"] boolValue] && [before[@"videoFrames"] integerValue] == 0);
        __block NSError *finishError = nil;
        __block NSDictionary *summary = nil;
        [recorder finishWithCompletion:^(__unused NSURL *output, NSDictionary *value, NSError *error) {
            summary = value; finishError = error;
        }];
        assert(finishError && [finishError.domain isEqual:@"Manual7.VideoRecorder"]);
        assert([summary[@"finished"] boolValue] && ![summary[@"started"] boolValue]);
        [recorder cancel]; // Idempotent after finish.

        NSURL *cancelURL = [url.URLByDeletingLastPathComponent
            URLByAppendingPathComponent:[NSString stringWithFormat:@"M7-%@.mov", NSUUID.UUID.UUIDString]];
        M7VideoRecorder *cancelled = [[M7VideoRecorder alloc] initWithOutputURL:cancelURL];
        [@"partial" writeToURL:cancelURL atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [cancelled cancel];
        assert(![NSFileManager.defaultManager fileExistsAtPath:cancelURL.path]);
        puts("Video recorder: empty finish diagnostics and idempotent cancellation passed.");
    }
    return 0;
}
