#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Pure helpers shared by the device adapter and the native regression tests.
// The selected format must be exposed by the current session, accepted by the
// requested DNG container, and identified by AVFoundation as Bayer RAW.
FOUNDATION_EXPORT NSNumber * _Nullable M7SelectCompatibleRAWFormat(
    NSArray<NSNumber *> *availableFormats,
    NSArray<NSNumber *> *dngFormats,
    NSSet<NSNumber *> *bayerFormats);
FOUNDATION_EXPORT NSString *M7RAWFourCC(uint32_t value);
FOUNDATION_EXPORT NSArray<NSDictionary *> *M7DescribeRAWFormats(
    NSArray<NSNumber *> *formats,
    NSSet<NSNumber *> *bayerFormats);

NS_ASSUME_NONNULL_END
