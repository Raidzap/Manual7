#import "M7RemoteServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>

static const NSUInteger M7RemoteMaximumHeaderBytes = 16 * 1024;
static const NSUInteger M7RemoteMaximumBodyBytes = 64 * 1024;

static NSError *M7RemoteSocketError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Manual7.RemoteServer" code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Erro no controle remoto."}];
}

static NSString *M7RemoteHTTPReason(NSInteger status) {
    switch (status) {
        case 200: return @"OK";
        case 202: return @"Accepted";
        case 400: return @"Bad Request";
        case 401: return @"Unauthorized";
        case 404: return @"Not Found";
        case 409: return @"Conflict";
        case 413: return @"Payload Too Large";
        case 431: return @"Request Header Fields Too Large";
        case 500: return @"Internal Server Error";
        case 503: return @"Service Unavailable";
        case 504: return @"Gateway Timeout";
        default: return @"Response";
    }
}

@interface M7RemoteServer ()
@property (nonatomic) uint16_t requestedPort;
@property (nonatomic) uint16_t port;
@property (nonatomic) NSString *pin;
@property (nonatomic, copy) M7RemoteRequestHandler handler;
@property (nonatomic) dispatch_queue_t acceptQueue;
@property (nonatomic) int listeningSocket;
@property (nonatomic, getter=isRunning) BOOL running;
@property (nonatomic) NSUInteger acceptedRequests;
@property (nonatomic) NSUInteger rejectedRequests;
@property (nonatomic) NSUInteger malformedRequests;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) NSTimeInterval lastRequestAt;
@property (nonatomic) NSUInteger generation;
@end

@implementation M7RemoteServer

- (instancetype)initWithPort:(uint16_t)port pin:(NSString *)pin
    handler:(M7RemoteRequestHandler)handler {
    if ((self = [super init])) {
        _requestedPort = port;
        _pin = [pin copy];
        _handler = [handler copy];
        _acceptQueue = dispatch_queue_create("dev.manual7.remote.accept", DISPATCH_QUEUE_SERIAL);
        _listeningSocket = -1;
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    @synchronized (self) {
        if (self.running) return YES;
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) {
            if (error) *error = M7RemoteSocketError(errno, @"Não foi possível criar o socket remoto.");
            return NO;
        }
        int enabled = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &enabled, sizeof(enabled));
#ifdef SO_NOSIGPIPE
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address);
        address.sin_family = AF_INET;
        address.sin_port = htons(self.requestedPort);
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
            NSInteger code = errno; close(server);
            if (error) *error = M7RemoteSocketError(code,
                @"A porta do controle remoto já está ocupada ou indisponível.");
            return NO;
        }
        if (listen(server, 8) != 0) {
            NSInteger code = errno; close(server);
            if (error) *error = M7RemoteSocketError(code,
                @"Não foi possível iniciar a escuta do controle remoto.");
            return NO;
        }
        socklen_t length = sizeof(address);
        if (getsockname(server, (struct sockaddr *)&address, &length) == 0)
            self.port = ntohs(address.sin_port);
        else self.port = self.requestedPort;
        self.listeningSocket = server;
        self.running = YES;
        NSUInteger generation = ++self.generation;
        self.startedAt = NSDate.date.timeIntervalSince1970;
        [self beginAcceptingSocket:server generation:generation];
        return YES;
    }
}

- (void)beginAcceptingSocket:(int)server generation:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.acceptQueue, ^{
        while (YES) {
            typeof(self) owner = weakSelf;
            if (!owner) break;
            @synchronized (owner) {
                if (!owner.running || owner.listeningSocket != server || owner.generation != generation) break;
            }
            int client = accept(server, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                @synchronized (owner) {
                    if (!owner.running || owner.listeningSocket != server || owner.generation != generation) break;
                }
                continue;
            }
#ifdef SO_NOSIGPIPE
            int enabled = 1;
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [owner handleClient:client];
            });
        }
    });
}

- (void)stop {
    @synchronized (self) {
        if (!self.running && self.listeningSocket < 0) return;
        self.running = NO;
        ++self.generation;
        int server = self.listeningSocket;
        self.listeningSocket = -1;
        if (server >= 0) { shutdown(server, SHUT_RDWR); close(server); }
    }
}

- (NSDictionary *)readRequestFromSocket:(int)client status:(NSInteger *)status {
    NSMutableData *data = [NSMutableData new];
    NSRange separator = NSMakeRange(NSNotFound, 0);
    NSUInteger expected = NSNotFound;
    NSDictionary *headers = nil;
    NSString *method = nil, *path = nil;
    while (data.length <= M7RemoteMaximumHeaderBytes + M7RemoteMaximumBodyBytes) {
        uint8_t buffer[4096];
        ssize_t count = recv(client, buffer, sizeof(buffer), 0);
        if (count <= 0) break;
        [data appendBytes:buffer length:(NSUInteger)count];
        if (separator.location == NSNotFound) {
            NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            separator = [data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)];
            if (separator.location == NSNotFound) {
                if (data.length > M7RemoteMaximumHeaderBytes) { if (status) *status = 431; return nil; }
                continue;
            }
            NSData *headData = [data subdataWithRange:NSMakeRange(0, separator.location)];
            NSString *head = [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding];
            NSArray<NSString *> *lines = [head componentsSeparatedByString:@"\r\n"];
            NSArray<NSString *> *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
            if (requestLine.count != 3) { if (status) *status = 400; return nil; }
            method = requestLine[0].uppercaseString;
            path = [requestLine[1] componentsSeparatedByString:@"?"][0];
            NSMutableDictionary *values = [NSMutableDictionary new];
            for (NSUInteger index = 1; index < lines.count; ++index) {
                NSRange colon = [lines[index] rangeOfString:@":"];
                if (colon.location == NSNotFound) continue;
                NSString *key = [[lines[index] substringToIndex:colon.location]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
                NSString *value = [[lines[index] substringFromIndex:colon.location+1]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                if (key.length) values[key] = value ?: @"";
            }
            headers = values;
            NSInteger contentLength = [headers[@"content-length"] integerValue];
            if (contentLength < 0 || contentLength > (NSInteger)M7RemoteMaximumBodyBytes) {
                if (status) *status = 413; return nil;
            }
            expected = NSMaxRange(separator) + (NSUInteger)contentLength;
        }
        if (expected != NSNotFound && data.length >= expected) break;
    }
    if (separator.location == NSNotFound || expected == NSNotFound || data.length < expected) {
        if (status) *status = 400; return nil;
    }
    NSUInteger bodyStart = NSMaxRange(separator);
    NSData *bodyData = [data subdataWithRange:NSMakeRange(bodyStart, expected-bodyStart)];
    NSDictionary *body = @{};
    if (bodyData.length) {
        NSError *jsonError = nil;
        id value = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
        if (![value isKindOfClass:NSDictionary.class]) {
            if (status) *status = 400; return nil;
        }
        body = value;
    }
    return @{ @"method":method ?: @"", @"path":path ?: @"", @"headers":headers ?: @{},
        @"body":body, @"requestID":NSUUID.UUID.UUIDString };
}

- (void)sendStatus:(NSInteger)status body:(NSDictionary *)body socket:(int)client {
    NSDictionary *safe = [body isKindOfClass:NSDictionary.class] ? body : @{};
    NSData *json = [NSJSONSerialization dataWithJSONObject:safe options:0 error:nil] ?: [NSData data];
    NSString *reason = M7RemoteHTTPReason(status);
    NSString *head = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n",
        (long)status, reason, (unsigned long)json.length];
    NSMutableData *response = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [response appendData:json];
    const uint8_t *bytes = response.bytes;
    NSUInteger sent = 0;
    while (sent < response.length) {
        ssize_t count = send(client, bytes+sent, response.length-sent, 0);
        if (count <= 0) break;
        sent += (NSUInteger)count;
    }
    shutdown(client, SHUT_RDWR);
    close(client);
}

- (void)handleClient:(int)client {
    @autoreleasepool {
        NSInteger parseStatus = 400;
        NSDictionary *request = [self readRequestFromSocket:client status:&parseStatus];
        if (!request) {
            @synchronized (self) { ++self.malformedRequests; self.lastRequestAt = NSDate.date.timeIntervalSince1970; }
            [self sendStatus:parseStatus body:@{ @"ok":@NO, @"error":@"Requisição HTTP/JSON inválida." }
                socket:client];
            return;
        }
        @synchronized (self) { ++self.acceptedRequests; self.lastRequestAt = NSDate.date.timeIntervalSince1970; }
        NSString *path = request[@"path"];
        if ([path isEqual:@"/v1/ping"]) {
            [self sendStatus:200 body:@{ @"ok":@YES, @"name":@"Manual7", @"version":@"0.5.0",
                @"port":@(self.port), @"authentication":@"X-Manual7-PIN" } socket:client];
            return;
        }
        NSString *providedPIN = request[@"headers"][@"x-manual7-pin"];
        if (!providedPIN.length || ![providedPIN isEqual:self.pin]) {
            @synchronized (self) { ++self.rejectedRequests; }
            [self sendStatus:401 body:@{ @"ok":@NO, @"error":@"PIN remoto ausente ou incorreto.",
                @"requestID":request[@"requestID"] ?: @"" } socket:client];
            return;
        }
        if (!self.handler) {
            [self sendStatus:503 body:@{ @"ok":@NO, @"error":@"Controlador M7 indisponível." } socket:client];
            return;
        }
        NSObject *replyLock = [NSObject new];
        __block BOOL replied = NO;
        void (^reply)(NSInteger, NSDictionary *) = ^(NSInteger status, NSDictionary *body) {
            @synchronized (replyLock) {
                if (replied) return;
                replied = YES;
            }
            [self sendStatus:status body:body socket:client];
        };
        @try {
            self.handler(request, reply);
        } @catch (NSException *exception) {
            reply(500, @{ @"ok":@NO, @"error":[NSString stringWithFormat:@"Exceção no controlador remoto: %@",
                exception.reason ?: exception.name] });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC),
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                reply(504, @{ @"ok":@NO, @"error":@"O M7 não respondeu em 10 segundos.",
                    @"requestID":request[@"requestID"] ?: @"" });
            });
    }
}

- (NSDictionary *)snapshot {
    @synchronized (self) {
        return @{ @"running":@(self.running), @"bind":@"127.0.0.1", @"port":@(self.port),
            @"pinRequired":@YES, @"startedAt":@(self.startedAt),
            @"lastRequestAt":@(self.lastRequestAt), @"acceptedRequests":@(self.acceptedRequests),
            @"rejectedRequests":@(self.rejectedRequests), @"malformedRequests":@(self.malformedRequests) };
    }
}

- (void)dealloc { [self stop]; }

@end
