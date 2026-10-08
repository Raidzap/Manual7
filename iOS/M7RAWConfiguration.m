#import "M7RAWConfiguration.h"

NSNumber *M7SelectCompatibleRAWFormat(NSArray<NSNumber *> *availableFormats,
    NSArray<NSNumber *> *dngFormats, NSSet<NSNumber *> *bayerFormats) {
    NSSet<NSNumber *> *dng = [NSSet setWithArray:dngFormats ?: @[]];
    for (NSNumber *format in availableFormats ?: @[]) {
        if ([dng containsObject:format] && [bayerFormats containsObject:format]) return format;
    }
    return nil;
}

NSString *M7RAWFourCC(uint32_t value) {
    char bytes[] = {(char)(value >> 24), (char)(value >> 16), (char)(value >> 8), (char)value, 0};
    BOOL printable = YES;
    for (NSUInteger index = 0; index < 4; ++index)
        if ((unsigned char)bytes[index] < 0x20 || (unsigned char)bytes[index] > 0x7e) printable = NO;
    return printable ? [NSString stringWithFormat:@"%c%c%c%c", bytes[0], bytes[1], bytes[2], bytes[3]] :
        [NSString stringWithFormat:@"0x%08x", (unsigned int)value];
}

NSArray<NSDictionary *> *M7DescribeRAWFormats(NSArray<NSNumber *> *formats,
    NSSet<NSNumber *> *bayerFormats) {
    NSMutableArray *result = [NSMutableArray new];
    for (NSNumber *format in formats ?: @[]) {
        [result addObject:@{ @"value":format, @"fourCC":M7RAWFourCC(format.unsignedIntValue),
            @"bayer":@([bayerFormats containsObject:format]) }];
    }
    return result;
}
