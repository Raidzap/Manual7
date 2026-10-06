#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^M7RemoteResponse)(NSInteger statusCode, NSDictionary *body);
typedef void (^M7RemoteRequestHandler)(NSDictionary *request, M7RemoteResponse response);

// Minimal HTTP/1.1 JSON server bound exclusively to the device loopback
// interface. Reach it from another computer through an authenticated SSH
// tunnel; all non-ping routes also require the per-controller PIN.
@interface M7RemoteServer : NSObject
@property (nonatomic, readonly) uint16_t port;
@property (nonatomic, readonly) NSString *transport;
@property (nonatomic, readonly, nullable) NSString *unixSocketPath;
@property (nonatomic, readonly, getter=isRunning) BOOL running;
- (instancetype)initWithPort:(uint16_t)port
                          pin:(NSString *)pin
                      handler:(M7RemoteRequestHandler)handler;
- (instancetype)initWithUnixSocketPath:(NSString *)path
                                   pin:(NSString *)pin
                               handler:(M7RemoteRequestHandler)handler;
- (instancetype)init NS_UNAVAILABLE;
- (BOOL)start:(NSError **)error;
- (void)stop;
- (NSDictionary *)snapshot;
@end

NS_ASSUME_NONNULL_END
