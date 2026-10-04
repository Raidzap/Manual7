#import "../iOS/M7CaptureResult.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        NSData *raw = [@"raw-fixture" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *jpeg = [@"jpeg-fixture" dataUsingEncoding:NSUTF8StringEncoding];
        NSError *failure = [NSError errorWithDomain:@"Test" code:-11800 userInfo:nil];
        // Both callback orders must retain only the requested format.
        for (NSNumber *jpegFirst in @[@YES, @NO]) {
            M7CaptureResult *r = [[M7CaptureResult alloc] initWithID:42 wantsRAW:YES];
            if (jpegFirst.boolValue) assert(![r receiveID:42 raw:NO data:jpeg metadata:@{} error:nil]);
            assert([r receiveID:42 raw:YES data:raw metadata:@{@"ISO":@100} error:nil]);
            if (!jpegFirst.boolValue) assert(![r receiveID:42 raw:NO data:jpeg metadata:@{} error:failure]);
            assert(![r finishWithError:nil]);
            assert([r.data isEqual:raw] && [r.metadata[@"ISO"] isEqual:@100]);
            assert(![r receiveID:42 raw:YES data:jpeg metadata:nil error:nil]);
        }
        M7CaptureResult *r = [[M7CaptureResult alloc] initWithID:7 wantsRAW:YES];
        assert(![r receiveID:6 raw:YES data:raw metadata:nil error:nil]);
        assert(![r receiveID:7 raw:NO data:jpeg metadata:nil error:nil]);
        assert([r finishWithError:nil] && !r.data);
        r = [[M7CaptureResult alloc] initWithID:7 wantsRAW:YES];
        assert([r receiveID:7 raw:YES data:raw metadata:nil error:failure]);
        assert(![r receiveID:7 raw:YES data:raw metadata:nil error:nil]);
        assert([r finishWithError:nil] == failure && !r.data);
        r = [[M7CaptureResult alloc] initWithID:8 wantsRAW:NO];
        assert([r receiveID:8 raw:NO data:jpeg metadata:nil error:nil]);
        assert([r finishWithError:failure] == failure);
        r = [[M7CaptureResult alloc] initWithID:8 wantsRAW:NO];
        assert([r receiveID:8 raw:NO data:jpeg metadata:nil error:nil]);
        assert(![r finishWithError:nil] && [r.data isEqual:jpeg]);
        r = [[M7CaptureResult alloc] initWithID:9 wantsRAW:YES];
        assert([r receiveID:9 raw:YES data:[NSData data] metadata:nil error:nil]);
        assert([r finishWithError:nil]);
        puts("Capture result: callback orders, RAW isolation, errors, missing data, stale/duplicate/late callbacks and JPEG passed.");
    }
    return 0;
}
