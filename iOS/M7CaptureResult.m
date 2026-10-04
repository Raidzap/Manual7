#import "M7CaptureResult.h"

@implementation M7CaptureResult {
    BOOL _receivedTarget;
    BOOL _finished;
}
- (instancetype)initWithID:(int64_t)captureID wantsRAW:(BOOL)raw {
    if ((self = [super init])) { _captureID = captureID; _wantsRAW = raw; }
    return self;
}
- (BOOL)receiveID:(int64_t)captureID raw:(BOOL)raw data:(NSData *)data
        metadata:(NSDictionary *)metadata error:(NSError *)error {
    if (_finished || captureID != _captureID || raw != _wantsRAW || _receivedTarget) return NO;
    _receivedTarget = YES;
    _processingError = error;
    _data = error ? nil : [data copy];
    _metadata = [metadata copy];
    return YES;
}
- (NSError *)finishWithError:(NSError *)error {
    _finished = YES;
    if (error || _processingError) return error ?: _processingError;
    if (!_receivedTarget || !_data.length) return [NSError errorWithDomain:@"Manual7.Capture" code:3
        userInfo:@{NSLocalizedDescriptionKey:_wantsRAW ? @"A captura terminou sem dados RAW válidos." : @"A captura terminou sem JPEG válido."}];
    return nil;
}
@end
