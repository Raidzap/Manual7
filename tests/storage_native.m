#import <Foundation/Foundation.h>
#import "../iOS/M7Storage.h"
#include <assert.h>

// Real filesystem checks, executable on macOS with Foundation. A regular file
// at the preferred directory reliably reproduces an unusable capture folder.
int main(void) {
    @autoreleasepool {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        assert([fm createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
        NSURL *primary = [root URLByAppendingPathComponent:@"Documents/Manual7" isDirectory:YES];
        NSURL *fallback = [root URLByAppendingPathComponent:@"Support/Manual7" isDirectory:YES];
        NSData *bytes = [@"image fixture" dataUsingEncoding:NSUTF8StringEncoding];
        M7Storage *store = [[M7Storage alloc] initWithCandidates:@[primary, fallback]];
        NSError *error = nil;
        assert([store prepare:&error] && !error);
        assert([store.directory isEqual:primary]);
        NSURL *first = [primary URLByAppendingPathComponent:@"first.jpg"];
        assert([bytes writeToURL:first options:NSDataWritingAtomic error:nil]);
        assert([fm createDirectoryAtURL:fallback withIntermediateDirectories:YES attributes:nil error:nil]);
        NSURL *second = [fallback URLByAppendingPathComponent:@"second.dng"];
        assert([bytes writeToURL:second options:NSDataWritingAtomic error:nil]);
        assert([store writeJSON:@{@"stage":@"saved"} filename:@"ultima-captura.json" error:&error]);
        NSArray *images = [store imageFilesWithError:&error];
        // Directory enumeration may return absolute URLs while appended URLs retain
        // a base URL; /var may also resolve to /private/var on macOS. Compare the
        // actual filesystem locations and contents, not NSURL representation.
        NSMutableSet *paths = [NSMutableSet new];
        for (NSURL *image in images) {
            [paths addObject:image.URLByResolvingSymlinksInPath.path];
            assert([[NSData dataWithContentsOfURL:image] isEqual:bytes]);
        }
        assert(!error && images.count == 2);
        assert([paths containsObject:first.URLByResolvingSymlinksInPath.path]);
        assert([paths containsObject:second.URLByResolvingSymlinksInPath.path]);
        // JSON receipts and directories named .jpg are not exported as images.
        assert([fm createDirectoryAtURL:[primary URLByAppendingPathComponent:@"fake.jpg"] withIntermediateDirectories:NO attributes:nil error:nil]);
        assert([store imageFilesWithError:nil].count == 2);

        assert([fm removeItemAtURL:primary error:nil]);
        assert([bytes writeToURL:[NSURL fileURLWithPath:primary.path isDirectory:NO] options:NSDataWritingAtomic error:nil]);
        error = nil;
        assert([store prepare:&error] && !error && [store.directory isEqual:fallback]);
        assert(store.attempts.count == 2 && ![store.attempts[0][@"writable"] boolValue]);
        assert([store writeJSON:@{@"stage":@"fallback"} filename:@"ultima-captura.json" error:&error]);
        NSData *json = [NSData dataWithContentsOfURL:[fallback URLByAppendingPathComponent:@"ultima-captura.json"]];
        assert([[[NSJSONSerialization JSONObjectWithData:json options:0 error:nil] objectForKey:@"stage"] isEqual:@"fallback"]);

        assert([fm removeItemAtURL:fallback error:nil]);
        assert([bytes writeToURL:[NSURL fileURLWithPath:fallback.path isDirectory:NO] options:NSDataWritingAtomic error:nil]);
        error = nil;
        assert(![store prepare:&error] && error && !store.directory);
        error = nil;
        assert(![store writeJSON:@{} filename:@"fail.json" error:&error] && error);
        error = nil;
        assert([store imageFilesWithError:&error].count == 0 && error);

        M7Storage *empty = [[M7Storage alloc] initWithCandidates:@[]];
        error = nil;
        assert(![empty prepare:&error] && error);
        assert([fm removeItemAtURL:root error:nil]);
        puts("Storage: preferred folder, fallback, discovery and failure reporting passed.");
    }
    return 0;
}
