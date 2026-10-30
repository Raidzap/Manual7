#import <Foundation/Foundation.h>
#import "M7WebcamCodec.h"

NS_ASSUME_NONNULL_BEGIN

// Authenticated multipart server on a mode-0600 Unix socket or the launchd
// bridge. GET /v1/webcam.mjpg streams JPEG parts; GET /v1/webcam.h264 streams
// Annex-B H.264 access units as parts with an X-Keyframe header.
@interface M7WebcamServer : NSObject
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger clientCount;
- (NSUInteger)clientCountForCodec:(M7WebcamCodec)codec;
// YES once after an H.264 client joined or the H.264 queue overflowed.
- (BOOL)consumeKeyframeRequest;
- (instancetype)initWithUnixSocketPath:(NSString *)path pin:(NSString *)pin;
- (instancetype)initWithBridgePort:(uint16_t)bridgePort
                publicUnixSocketPath:(NSString *)path
                               magic:(NSString *)magic
                                 pin:(NSString *)pin;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)publishJPEG:(NSData *)jpeg width:(NSUInteger)width height:(NSUInteger)height;
- (void)publishH264:(NSData *)accessUnit keyframe:(BOOL)keyframe
              width:(NSUInteger)width height:(NSUInteger)height;
// Ends the clients of one codec, e.g. after the H.264 encoder failed.
- (void)closeClientsForCodec:(M7WebcamCodec)codec;
- (NSDictionary *)snapshot;
@end

NS_ASSUME_NONNULL_END
