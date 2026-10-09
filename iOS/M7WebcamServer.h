#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Authenticated multipart-MJPEG server on a mode-0600 Unix socket.
@interface M7WebcamServer : NSObject
@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSUInteger clientCount;
- (instancetype)initWithUnixSocketPath:(NSString *)path pin:(NSString *)pin;
- (instancetype)initWithBridgePort:(uint16_t)bridgePort
                publicUnixSocketPath:(NSString *)path
                               magic:(NSString *)magic
                                 pin:(NSString *)pin;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (void)publishJPEG:(NSData *)jpeg width:(NSUInteger)width height:(NSUInteger)height;
- (NSDictionary *)snapshot;
@end

NS_ASSUME_NONNULL_END
