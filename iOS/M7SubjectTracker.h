#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

// Synchronous Vision analysis. Confine this object to one serial queue.
@interface M7SubjectTracker : NSObject
@property (nonatomic, readonly) CGPoint center;
- (void)reset;
- (NSDictionary *)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer
                          timeOffset:(NSTimeInterval)timeOffset
                              record:(BOOL)record;
- (NSArray<NSDictionary *> *)trackingPoints;
- (NSDictionary *)snapshot;
@end

NS_ASSUME_NONNULL_END
