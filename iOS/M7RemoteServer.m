#import "M7RemoteServer.h"
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static const NSUInteger M7RemoteMaximumHeaderBytes = 16 * 1024;
static const NSUInteger M7RemoteMaximumBodyBytes = 64 * 1024;

static NSError *M7RemoteSocketError(NSInteger code, NSString *operation, NSString *message) {
    NSString *reason = code > 0 ? [NSString stringWithUTF8String:strerror((int)code)] : @"";
    return [NSError errorWithDomain:@"Manual7.RemoteServer" code:code
        userInfo:@{NSLocalizedDescriptionKey:message ?: @"Erro no controle remoto.",
            NSLocalizedFailureReasonErrorKey:reason ?: @"", @"operation":operation ?: @"",
            @"posixCode":@(code)}];
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
@property (nonatomic) NSString *requestedUnixSocketPath;
@property (nonatomic) uint16_t port;
@property (nonatomic) NSString *transport;
@property (nonatomic) NSString *unixSocketPath;
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
@property (nonatomic) dev_t unixSocketDevice;
@property (nonatomic) ino_t unixSocketInode;
@property (nonatomic) BOOL ownsUnixSocketPath;
@end

@implementation M7RemoteServer

- (instancetype)initWithPort:(uint16_t)port pin:(NSString *)pin
    handler:(M7RemoteRequestHandler)handler {
    if ((self = [super init])) {
        _requestedPort = port;
        _transport = @"tcp";
        _pin = [pin copy];
        _handler = [handler copy];
        _acceptQueue = dispatch_queue_create("dev.manual7.remote.accept", DISPATCH_QUEUE_SERIAL);
        _listeningSocket = -1;
    }
    return self;
}

- (instancetype)initWithUnixSocketPath:(NSString *)path pin:(NSString *)pin
    handler:(M7RemoteRequestHandler)handler {
    if ((self = [super init])) {
        _requestedUnixSocketPath = [path copy];
        _transport = @"unix";
        _pin = [pin copy];
        _handler = [handler copy];
        _acceptQueue = dispatch_queue_create("dev.manual7.remote.accept", DISPATCH_QUEUE_SERIAL);
        _listeningSocket = -1;
    }
    return self;
}

- (BOOL)finishStartingSocket:(int)server error:(NSError **)error {
    if (listen(server, 8) != 0) {
        NSInteger code = errno; close(server);
        if (error) *error = M7RemoteSocketError(code, @"listen",
            @"Não foi possível iniciar a escuta do controle remoto.");
        return NO;
    }
    self.listeningSocket = server;
    self.running = YES;
    NSUInteger generation = ++self.generation;
    self.startedAt = NSDate.date.timeIntervalSince1970;
    [self beginAcceptingSocket:server generation:generation];
    return YES;
}

- (BOOL)startUnixSocket:(NSError **)error {
    NSData *pathData = [self.requestedUnixSocketPath dataUsingEncoding:NSUTF8StringEncoding];
    if (!pathData.length || pathData.length >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        if (error) *error = M7RemoteSocketError(ENAMETOOLONG, @"path",
            @"O caminho do socket Unix da API é inválido.");
        return NO;
    }
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) {
        if (error) *error = M7RemoteSocketError(errno, @"socket(AF_UNIX)",
            @"Não foi possível criar o socket Unix da API.");
        return NO;
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
    const char *path = self.requestedUnixSocketPath.fileSystemRepresentation;
    unlink(path); // A Camera é a única proprietária desse endpoint efêmero.
    struct sockaddr_un address = {0};
#if defined(__APPLE__)
    address.sun_len = sizeof(address);
#endif
    address.sun_family = AF_UNIX;
    memcpy(address.sun_path, path, pathData.length + 1);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0) {
        NSInteger code = errno; close(server);
        if (error) *error = M7RemoteSocketError(code, @"bind(AF_UNIX)",
            @"Não foi possível criar o endpoint Unix da API remota.");
        return NO;
    }
    if (chmod(path, S_IRUSR | S_IWUSR) != 0) {
        NSInteger code = errno; close(server); unlink(path);
        if (error) *error = M7RemoteSocketError(code, @"chmod(AF_UNIX)",
            @"Não foi possível proteger o endpoint Unix da API remota.");
        return NO;
    }
    struct stat info = {0};
    if (lstat(path, &info) == 0) {
        self.unixSocketDevice = info.st_dev;
        self.unixSocketInode = info.st_ino;
        self.ownsUnixSocketPath = YES;
    }
    self.unixSocketPath = self.requestedUnixSocketPath;
    self.port = 0;
    if (![self finishStartingSocket:server error:error]) {
        unlink(path); self.ownsUnixSocketPath = NO; self.unixSocketPath = nil;
        return NO;
    }
    return YES;
}

- (BOOL)start:(NSError **)error {
    @synchronized (self) {
        if (self.running) return YES;
        if (self.requestedUnixSocketPath.length) return [self startUnixSocket:error];
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) {
            if (error) *error = M7RemoteSocketError(errno, @"socket(AF_INET)",
                @"Não foi possível criar o socket TCP remoto.");
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
            if (error) *error = M7RemoteSocketError(code, @"bind(AF_INET)",
                @"O processo não conseguiu reservar a porta TCP da API remota.");
            return NO;
        }
        socklen_t length = sizeof(address);
        if (getsockname(server, (struct sockaddr *)&address, &length) == 0)
            self.port = ntohs(address.sin_port);
        else self.port = self.requestedPort;
        return [self finishStartingSocket:server error:error];
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
        if (self.ownsUnixSocketPath && self.unixSocketPath.length) {
            struct stat info = {0};
            if (lstat(self.unixSocketPath.fileSystemRepresentation, &info) == 0 &&
                info.st_dev == self.unixSocketDevice && info.st_ino == self.unixSocketInode)
                unlink(self.unixSocketPath.fileSystemRepresentation);
        }
        self.ownsUnixSocketPath = NO;
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
            [self sendStatus:200 body:@{ @"ok":@YES, @"name":@"Manual7", @"version":@"0.7.0",
                @"transport":self.transport ?: @"", @"port":@(self.port),
                @"authentication":@"X-Manual7-PIN" } socket:client];
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
        struct stat info = {0};
        BOOL unixSocketExists = self.unixSocketPath.length &&
            lstat(self.unixSocketPath.fileSystemRepresentation, &info) == 0;
        NSString *binding = [self.transport isEqual:@"unix"] ? (self.unixSocketPath ?: @"") : @"127.0.0.1";
        return @{ @"running":@(self.running), @"transport":self.transport ?: @"", @"bind":binding,
            @"port":@(self.port), @"unixSocketPath":self.unixSocketPath ?: @"",
            @"unixSocketExists":@(unixSocketExists),
            @"unixSocketPermissions":unixSocketExists ?
                [NSString stringWithFormat:@"%04o", (unsigned int)(info.st_mode & 0777)] : @"",
            @"unixSocketOwnerUID":unixSocketExists ? @(info.st_uid) : @0,
            @"unixSocketOwnerGID":unixSocketExists ? @(info.st_gid) : @0,
            @"pinRequired":@YES, @"startedAt":@(self.startedAt),
            @"lastRequestAt":@(self.lastRequestAt), @"acceptedRequests":@(self.acceptedRequests),
            @"rejectedRequests":@(self.rejectedRequests), @"malformedRequests":@(self.malformedRequests) };
    }
}

- (void)dealloc { [self stop]; }

@end
