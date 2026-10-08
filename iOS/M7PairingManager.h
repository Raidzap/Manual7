#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const M7PairingErrorDomain;

// Parses and validates a one-use Manual7 QR payload. callbackURL and token are
// intentionally returned only to the caller; snapshot never exposes either.
FOUNDATION_EXPORT NSDictionary * _Nullable M7ParsePairingPayload(NSString *payload,
    NSError * _Nullable * _Nullable error);

@interface M7PairingManager : NSObject

// Run on a serial analysis queue. A frame with no Manual7 QR returns nil and no
// error. A malformed Manual7 QR returns a validation error.
- (NSDictionary * _Nullable)pairingPayloadFromPixelBuffer:(CVPixelBufferRef)pixelBuffer
    error:(NSError * _Nullable * _Nullable)error;

- (void)submitPairing:(NSDictionary *)pairing
    pin:(NSString *)pin
    preferredSSHPort:(NSNumber *)preferredSSHPort
    availableSSHPorts:(NSArray<NSNumber *> *)availableSSHPorts
    apiSocketPath:(NSString *)apiSocketPath
    webcamSocketPath:(NSString *)webcamSocketPath
    completion:(void (^)(NSDictionary * _Nullable response, NSError * _Nullable error))completion;

- (void)cancel;
- (NSDictionary *)snapshot;

@end

NS_ASSUME_NONNULL_END
