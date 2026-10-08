#import <Foundation/Foundation.h>
#import "../iOS/M7RAWConfiguration.h"
#include <assert.h>

int main(void) {
    @autoreleasepool {
        // rgg4 is the 14-bit Bayer RGGB format observed on the iPhone 7 Plus.
        NSNumber *rgg4 = @(0x72676734u);
        NSNumber *other = @(0x12345678u);
        NSSet *bayer = [NSSet setWithObject:rgg4];
        assert([M7RAWFourCC(rgg4.unsignedIntValue) isEqual:@"rgg4"]);
        assert([M7SelectCompatibleRAWFormat(@[other, rgg4], @[rgg4], bayer) isEqual:rgg4]);
        assert(M7SelectCompatibleRAWFormat(@[rgg4], @[other], bayer) == nil);
        assert(M7SelectCompatibleRAWFormat(@[other], @[other], bayer) == nil);
        NSArray *description = M7DescribeRAWFormats(@[rgg4, other], bayer);
        assert([description[0][@"bayer"] boolValue]);
        assert(![description[1][@"bayer"] boolValue]);
        assert([NSJSONSerialization isValidJSONObject:description]);
        puts("RAW configuration: FourCC and Bayer/DNG intersection passed.");
    }
    return 0;
}
