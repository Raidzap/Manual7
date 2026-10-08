#import "M7PairingManager.h"
#import <Vision/Vision.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#import <arpa/inet.h>

NSString * const M7PairingErrorDomain = @"dev.manual7.pairing";

static NSError *M7PairingError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:M7PairingErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Falha no pareamento."}];
}

static BOOL M7PrivateIPv4(NSString *host) {
    struct in_addr address = {0};
    if (inet_pton(AF_INET, host.UTF8String, &address) != 1) return NO;
    uint32_t value = ntohl(address.s_addr);
    return (value & 0xff000000U) == 0x0a000000U ||
        (value & 0xfff00000U) == 0xac100000U ||
        (value & 0xffff0000U) == 0xc0a80000U ||
        (value & 0xffff0000U) == 0xa9fe0000U;
}

static BOOL M7ValidToken(NSString *token) {
    if (token.length < 32 || token.length > 128) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [token rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSDictionary *M7ParsePairingPayload(NSString *payload, NSError **error) {
    NSURLComponents *parts = [NSURLComponents componentsWithString:payload ?: @""];
    if (![parts.scheme.lowercaseString isEqual:@"manual7"] ||
        ![parts.host.lowercaseString isEqual:@"pair"]) {
        if (error) *error = M7PairingError(1, @"O QR não é um código de pareamento Manual7.");
        return nil;
    }
    NSMutableDictionary<NSString *, NSString *> *query = [NSMutableDictionary new];
    for (NSURLQueryItem *item in parts.queryItems)
        if (item.name.length && item.value.length && !query[item.name]) query[item.name] = item.value;
    NSString *callbackString = query[@"callback"];
    NSString *token = query[@"token"];
    NSURLComponents *callback = [NSURLComponents componentsWithString:callbackString ?: @""];
    NSInteger port = callback.port.integerValue;
    if (![callback.scheme.lowercaseString isEqual:@"http"] || !M7PrivateIPv4(callback.host) ||
        port < 1024 || port > UINT16_MAX || ![callback.path isEqual:@"/v1/pair"] ||
        callback.user.length || callback.password.length || callback.query.length || callback.fragment.length) {
        if (error) *error = M7PairingError(2,
            @"O endereço do notebook no QR é inválido ou não pertence à rede local.");
        return nil;
    }
    if (!M7ValidToken(token)) {
        if (error) *error = M7PairingError(3, @"O token de uso único do QR é inválido.");
        return nil;
    }
    NSString *name = query[@"name"] ?: @"Notebook Linux";
    if (name.length > 64) name = [name substringToIndex:64];
    return @{ @"callbackURL":callback.URL, @"token":token, @"name":name,
        @"host":callback.host, @"port":@(port) };
}

@interface M7PairingManager ()
@property (nonatomic) dispatch_queue_t stateQueue;
@property (nonatomic) NSURLSession *session;
@property (nonatomic) NSMutableDictionary *state;
@end

@implementation M7PairingManager

- (instancetype)init {
    if ((self = [super init])) {
        _stateQueue = dispatch_queue_create("dev.manual7.pairing.state", DISPATCH_QUEUE_SERIAL);
        _state = [@{ @"state":@"idle", @"framesAnalyzed":@0, @"codesSeen":@0,
            @"submissions":@0, @"accepted":@0, @"failures":@0 } mutableCopy];
    }
    return self;
}

- (void)updateState:(NSDictionary *)values {
    dispatch_sync(self.stateQueue, ^{ [self.state addEntriesFromDictionary:values]; });
}

- (NSDictionary *)pairingPayloadFromPixelBuffer:(CVPixelBufferRef)pixelBuffer error:(NSError **)error {
    if (!pixelBuffer) return nil;
    __block NSUInteger frames = 0;
    dispatch_sync(self.stateQueue, ^{
        frames = [self.state[@"framesAnalyzed"] unsignedIntegerValue] + 1;
        self.state[@"framesAnalyzed"] = @(frames);
        self.state[@"state"] = @"scanning";
    });
    VNDetectBarcodesRequest *request = [VNDetectBarcodesRequest new];
    request.symbologies = @[VNBarcodeSymbologyQR];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
        orientation:kCGImagePropertyOrientationUp options:@{}];
    NSError *visionError = nil;
    if (![handler performRequests:@[request] error:&visionError]) {
        if (error) *error = visionError ?: M7PairingError(4, @"O Vision não conseguiu analisar o QR.");
        [self updateState:@{ @"state":@"scanFailed", @"lastError":(visionError.localizedDescription ?: @"") }];
        return nil;
    }
    for (VNBarcodeObservation *observation in request.results) {
        NSString *value = observation.payloadStringValue;
        if (!value.length || ![value.lowercaseString hasPrefix:@"manual7://"]) continue;
        __block NSUInteger codes = 0;
        dispatch_sync(self.stateQueue, ^{
            codes = [self.state[@"codesSeen"] unsignedIntegerValue] + 1;
            self.state[@"codesSeen"] = @(codes);
        });
        NSError *parseError = nil;
        NSDictionary *pairing = M7ParsePairingPayload(value, &parseError);
        if (!pairing) {
            if (error) *error = parseError;
            [self updateState:@{ @"state":@"codeRejected", @"lastError":parseError.localizedDescription ?: @"" }];
            return nil;
        }
        [self updateState:@{ @"state":@"recognized", @"callbackHost":pairing[@"host"],
            @"callbackPort":pairing[@"port"], @"computerName":pairing[@"name"],
            @"recognizedAt":@(NSDate.date.timeIntervalSince1970), @"lastError":@"" }];
        return pairing;
    }
    return nil;
}

- (void)submitPairing:(NSDictionary *)pairing pin:(NSString *)pin
    preferredSSHPort:(NSNumber *)preferredSSHPort availableSSHPorts:(NSArray<NSNumber *> *)availableSSHPorts
    completion:(void (^)(NSDictionary *, NSError *))completion {
    NSURL *url = pairing[@"callbackURL"];
    NSString *token = pairing[@"token"];
    if (!url || !M7ValidToken(token) || pin.length != 6) {
        if (completion) completion(nil, M7PairingError(5, @"Os dados de pareamento estão incompletos."));
        return;
    }
    NSString *deviceName = @"Apple device";
    NSString *systemVersion = NSProcessInfo.processInfo.operatingSystemVersionString ?: @"";
#if TARGET_OS_IPHONE
    deviceName = UIDevice.currentDevice.model ?: @"iPhone";
    systemVersion = UIDevice.currentDevice.systemVersion ?: @"";
#endif
    NSDictionary *body = @{ @"version":@"0.7.1", @"pin":pin,
        @"preferredSSHPort":preferredSSHPort ?: @0,
        @"availableSSHPorts":availableSSHPorts ?: @[],
        @"apiSocket":@"/var/tmp/Manual7-api.sock",
        @"webcamSocket":@"/var/tmp/Manual7-webcam.sock",
        @"device":deviceName, @"systemVersion":systemVersion };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!data) { if (completion) completion(nil, jsonError); return; }

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 10;
    configuration.timeoutIntervalForResource = 20;
    if ([configuration respondsToSelector:@selector(setWaitsForConnectivity:)])
        configuration.waitsForConnectivity = YES;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    self.session = session;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = data;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:token forHTTPHeaderField:@"X-Manual7-Pairing"];
    dispatch_sync(self.stateQueue, ^{
        self.state[@"state"] = @"submitting";
        self.state[@"submissions"] = @([self.state[@"submissions"] unsignedIntegerValue] + 1);
        self.state[@"submittedAt"] = @(NSDate.date.timeIntervalSince1970);
    });
    __weak typeof(self) weakSelf = self;
    [[session dataTaskWithRequest:request completionHandler:^(NSData *responseData,
        NSURLResponse *response, NSError *networkError) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        NSError *resultError = networkError;
        NSDictionary *responseObject = nil;
        if (!resultError && responseData.length) {
            id object = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
            if ([object isKindOfClass:NSDictionary.class]) responseObject = object;
        }
        if (!resultError && (http.statusCode < 200 || http.statusCode >= 300))
            resultError = M7PairingError(6, [NSString stringWithFormat:
                @"O notebook recusou o pareamento (HTTP %ld).", (long)http.statusCode]);
        M7PairingManager *owner = weakSelf;
        if (owner) dispatch_sync(owner.stateQueue, ^{
            owner.state[@"httpStatus"] = @(http.statusCode);
            owner.state[@"completedAt"] = @(NSDate.date.timeIntervalSince1970);
            if (resultError) {
                owner.state[@"state"] = @"failed";
                owner.state[@"failures"] = @([owner.state[@"failures"] unsignedIntegerValue] + 1);
                owner.state[@"lastError"] = resultError.localizedDescription ?: @"";
            } else {
                owner.state[@"state"] = @"accepted";
                owner.state[@"accepted"] = @([owner.state[@"accepted"] unsignedIntegerValue] + 1);
                owner.state[@"lastError"] = @"";
            }
        });
        if (completion) completion(responseObject, resultError);
        [session finishTasksAndInvalidate];
        if (owner.session == session) owner.session = nil;
    }] resume];
}

- (void)cancel {
    [self.session invalidateAndCancel];
    self.session = nil;
    [self updateState:@{ @"state":@"cancelled", @"cancelledAt":@(NSDate.date.timeIntervalSince1970) }];
}

- (NSDictionary *)snapshot {
    __block NSDictionary *copy;
    dispatch_sync(self.stateQueue, ^{ copy = [self.state copy]; });
    return copy;
}

@end
