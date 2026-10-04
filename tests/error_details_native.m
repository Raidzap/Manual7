#import <Foundation/Foundation.h>
#import "../iOS/M7ErrorDetails.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        // Synthetic fixture, not a diagnosis of the device's unknown OSStatus.
        NSError *inner = [NSError errorWithDomain:NSOSStatusErrorDomain code:-12345 userInfo:@{@"marker":@"inner"}];
        NSError *outer = [NSError errorWithDomain:@"AVFoundationErrorDomain" code:-11800 userInfo:@{
            NSUnderlyingErrorKey:inner, NSLocalizedDescriptionKey:@"Capture failed",
            NSLocalizedFailureReasonErrorKey:@"Test reason", @"payload":[NSData dataWithBytes:"abc" length:3]}];
        NSDictionary *result = M7ErrorDetails(outer);
        assert([result[@"code"] integerValue] == -11800);
        assert([result[@"failureReason"] isEqual:@"Test reason"]);
        assert([result[@"userInfo"][NSUnderlyingErrorKey][@"code"] integerValue] == -12345);
        assert([result[@"userInfo"][@"payload"][@"bytes"] integerValue] == 3);
        assert([NSJSONSerialization isValidJSONObject:result]);
        assert([NSJSONSerialization dataWithJSONObject:result options:0 error:nil].length > 0);
        assert(M7ErrorDetails(nil).count == 0);
        // Recursive userInfo must terminate and remain JSON-safe.
        NSMutableDictionary *cycle = [NSMutableDictionary new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-circular-container"
        [cycle setObject:cycle forKey:@"cycle"];
#pragma clang diagnostic pop
        NSError *recursive = [NSError errorWithDomain:@"Test" code:1 userInfo:cycle];
        assert([NSJSONSerialization isValidJSONObject:M7ErrorDetails(recursive)]);
        [cycle removeAllObjects];
        puts("Error details: underlying error, JSON serialization and depth limit passed.");
    }
    return 0;
}
