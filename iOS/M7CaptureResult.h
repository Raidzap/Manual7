#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// One request, potentially two photo callbacks. Confined to the session queue.
@interface M7CaptureResult : NSObject
@property (nonatomic, readonly) int64_t captureID;
@property (nonatomic, readonly) BOOL wantsRAW;
@property (nonatomic, readonly, nullable) NSData *data;
@property (nonatomic, readonly, nullable) NSDictionary *metadata;
@property (nonatomic, readonly, nullable) NSError *processingError;
- (instancetype)initWithID:(int64_t)captureID wantsRAW:(BOOL)raw;
- (BOOL)receiveID:(int64_t)captureID raw:(BOOL)raw data:(nullable NSData *)data
        metadata:(nullable NSDictionary *)metadata error:(nullable NSError *)error;
// Closes the request. A processed companion can never stand in for missing RAW.
- (nullable NSError *)finishWithError:(nullable NSError *)error;
@end
NS_ASSUME_NONNULL_END
