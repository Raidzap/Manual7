#import "M7WebcamServer.h"
#import <errno.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>

static const void *M7WebcamSendQueueKey = &M7WebcamSendQueueKey;

static NSError *M7WebcamSocketError(NSInteger code, NSString *operation, NSString *message) {
    NSString *reason = code > 0 ? [NSString stringWithUTF8String:strerror((int)code)] : @"";
    return [NSError errorWithDomain:@"Manual7.WebcamServer" code:code userInfo:@{
        NSLocalizedDescriptionKey:message ?: @"Erro no servidor da webcam.",
        NSLocalizedFailureReasonErrorKey:reason ?: @"", @"operation":operation ?: @"",
        @"posixCode":@(code)}];
}

static BOOL M7WebcamSendAll(int socketFD, NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger sent = 0;
    while (sent < data.length) {
        ssize_t count = send(socketFD, bytes + sent, data.length - sent, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        sent += (NSUInteger)count;
    }
    return YES;
}

@interface M7WebcamServer ()
@property (nonatomic) NSString *path;
@property (nonatomic) NSString *pin;
@property (nonatomic) dispatch_queue_t acceptQueue;
@property (nonatomic) dispatch_queue_t sendQueue;
@property (nonatomic) int listeningSocket;
@property (nonatomic) NSMutableSet<NSNumber *> *clients;
@property (nonatomic, getter=isRunning) BOOL running;
@property (nonatomic) NSUInteger generation;
@property (nonatomic) dev_t socketDevice;
@property (nonatomic) ino_t socketInode;
@property (nonatomic) NSUInteger clientsAccepted;
@property (nonatomic) NSUInteger clientsRejected;
@property (nonatomic) NSUInteger clientsDropped;
@property (nonatomic) NSUInteger framesPublished;
@property (nonatomic) NSUInteger bytesPublished;
@property (nonatomic) NSUInteger lastWidth;
@property (nonatomic) NSUInteger lastHeight;
@property (nonatomic) NSTimeInterval startedAt;
@property (nonatomic) NSTimeInterval lastFrameAt;
@end

@implementation M7WebcamServer

- (instancetype)initWithUnixSocketPath:(NSString *)path pin:(NSString *)pin {
    if ((self = [super init])) {
        _path = [path copy]; _pin = [pin copy];
        _acceptQueue = dispatch_queue_create("dev.manual7.webcam.accept", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("dev.manual7.webcam.send", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_sendQueue, M7WebcamSendQueueKey,
            (void *)M7WebcamSendQueueKey, NULL);
        _listeningSocket = -1; _clients = [NSMutableSet new];
    }
    return self;
}

- (BOOL)start:(NSError **)error {
    @synchronized (self) {
        if (self.running) return YES;
        const char *path = self.path.fileSystemRepresentation;
        if (!path || strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
            if (error) *error = M7WebcamSocketError(ENAMETOOLONG, @"path",
                @"O caminho do socket da webcam é inválido.");
            return NO;
        }
        int server = socket(AF_UNIX, SOCK_STREAM, 0);
        if (server < 0) {
            if (error) *error = M7WebcamSocketError(errno, @"socket(AF_UNIX)",
                @"Não foi possível criar o socket da webcam.");
            return NO;
        }
#ifdef SO_NOSIGPIPE
        int enabled = 1;
        setsockopt(server, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
        unlink(path);
        struct sockaddr_un address = {0};
#if defined(__APPLE__)
        address.sun_len = sizeof(address);
#endif
        address.sun_family = AF_UNIX;
        strncpy(address.sun_path, path, sizeof(address.sun_path)-1);
        if (bind(server, (struct sockaddr *)&address, sizeof(address)) != 0 ||
            chmod(path, S_IRUSR | S_IWUSR) != 0 || listen(server, 2) != 0) {
            NSInteger code = errno; close(server); unlink(path);
            if (error) *error = M7WebcamSocketError(code, @"bind/chmod/listen(AF_UNIX)",
                @"Não foi possível iniciar o endpoint protegido da webcam.");
            return NO;
        }
        struct stat info = {0};
        if (lstat(path, &info) == 0) { self.socketDevice = info.st_dev; self.socketInode = info.st_ino; }
        self.listeningSocket = server; self.running = YES; self.startedAt = NSDate.date.timeIntervalSince1970;
        NSUInteger generation = ++self.generation;
        [self beginAccepting:server generation:generation];
        return YES;
    }
}

- (void)beginAccepting:(int)server generation:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.acceptQueue, ^{
        while (YES) {
            typeof(self) owner = weakSelf; if (!owner) break;
            @synchronized (owner) {
                if (!owner.running || owner.listeningSocket != server || owner.generation != generation) break;
            }
            int client = accept(server, NULL, NULL);
            if (client < 0) {
                if (errno == EINTR) continue;
                @synchronized (owner) { if (!owner.running || owner.generation != generation) break; }
                continue;
            }
#ifdef SO_NOSIGPIPE
            int enabled = 1; setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
            struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            struct timeval receiveTimeout = {.tv_sec = 3, .tv_usec = 0};
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                [owner handleClient:client generation:generation];
            });
        }
    });
}

- (void)handleClient:(int)client generation:(NSUInteger)generation {
    @autoreleasepool {
        NSMutableData *requestData = [NSMutableData new];
        NSData *marker = [@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        while (requestData.length < 16*1024 &&
               [requestData rangeOfData:marker options:0 range:NSMakeRange(0, requestData.length)].location == NSNotFound) {
            uint8_t buffer[2048]; ssize_t count = recv(client, buffer, sizeof(buffer), 0);
            if (count <= 0) break;
            [requestData appendBytes:buffer length:(NSUInteger)count];
        }
        NSString *request = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSString *> *lines = [request componentsSeparatedByString:@"\r\n"];
        BOOL route = [lines.firstObject hasPrefix:@"GET /v1/webcam.mjpg "];
        NSString *providedPIN = @"";
        for (NSString *line in lines) {
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            NSString *key = [[[line substringToIndex:colon.location]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] lowercaseString];
            if ([key isEqual:@"x-manual7-pin"])
                providedPIN = [[line substringFromIndex:colon.location+1]
                    stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        }
        if (!route || ![providedPIN isEqual:self.pin]) {
            @synchronized (self) { ++self.clientsRejected; }
            NSString *status = route ? @"401 Unauthorized" : @"404 Not Found";
            NSString *response = [NSString stringWithFormat:@"HTTP/1.1 %@\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", status];
            M7WebcamSendAll(client, [response dataUsingEncoding:NSUTF8StringEncoding]);
            close(client); return;
        }
        NSString *header = @"HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=m7frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
        if (!M7WebcamSendAll(client, [header dataUsingEncoding:NSUTF8StringEncoding])) {
            close(client); return;
        }
        @synchronized (self) {
            if (!self.running || self.generation != generation) { close(client); return; }
            [self.clients addObject:@(client)]; ++self.clientsAccepted;
        }
    }
}

- (NSUInteger)clientCount { @synchronized (self) { return self.clients.count; } }

- (void)publishJPEG:(NSData *)jpeg width:(NSUInteger)width height:(NSUInteger)height {
    if (!jpeg.length) return;
    dispatch_async(self.sendQueue, ^{
        NSArray<NSNumber *> *clients = nil;
        @synchronized (self) { clients = self.clients.allObjects; }
        if (!clients.count) return;
        NSString *head = [NSString stringWithFormat:
            @"--m7frame\r\nContent-Type: image/jpeg\r\nContent-Length: %lu\r\nX-Width: %lu\r\nX-Height: %lu\r\n\r\n",
            (unsigned long)jpeg.length, (unsigned long)width, (unsigned long)height];
        NSMutableData *frame = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [frame appendData:jpeg]; [frame appendBytes:"\r\n" length:2];
        NSUInteger delivered = 0;
        for (NSNumber *number in clients) {
            int client = number.intValue;
            if (M7WebcamSendAll(client, frame)) { ++delivered; continue; }
            shutdown(client, SHUT_RDWR); close(client);
            @synchronized (self) { [self.clients removeObject:number]; ++self.clientsDropped; }
        }
        if (delivered) @synchronized (self) {
            ++self.framesPublished; self.bytesPublished += jpeg.length * delivered;
            self.lastWidth = width; self.lastHeight = height;
            self.lastFrameAt = NSDate.date.timeIntervalSince1970;
        }
    });
}

- (void)stop {
    int server = -1;
    @synchronized (self) {
        if (!self.running && self.listeningSocket < 0) return;
        self.running = NO; ++self.generation; server = self.listeningSocket; self.listeningSocket = -1;
    }
    if (server >= 0) { shutdown(server, SHUT_RDWR); close(server); }
    void (^closeClients)(void) = ^{
        NSArray<NSNumber *> *clients = nil;
        @synchronized (self) { clients = self.clients.allObjects; [self.clients removeAllObjects]; }
        for (NSNumber *number in clients) { shutdown(number.intValue, SHUT_RDWR); close(number.intValue); }
    };
    if (dispatch_get_specific(M7WebcamSendQueueKey)) closeClients();
    else dispatch_sync(self.sendQueue, closeClients);
    struct stat info = {0};
    if (lstat(self.path.fileSystemRepresentation, &info) == 0 &&
        info.st_dev == self.socketDevice && info.st_ino == self.socketInode)
        unlink(self.path.fileSystemRepresentation);
}

- (NSDictionary *)snapshot {
    @synchronized (self) {
        struct stat info = {0}; BOOL exists = lstat(self.path.fileSystemRepresentation, &info) == 0;
        return @{ @"running":@(self.running), @"transport":@"multipart-mjpeg-unix",
            @"unixSocketPath":self.path, @"unixSocketExists":@(exists),
            @"unixSocketPermissions":exists ? [NSString stringWithFormat:@"%04o",
                (unsigned int)(info.st_mode & 0777)] : @"",
            @"clientCount":@(self.clients.count), @"clientsAccepted":@(self.clientsAccepted),
            @"clientsRejected":@(self.clientsRejected), @"clientsDropped":@(self.clientsDropped),
            @"framesPublished":@(self.framesPublished), @"bytesPublished":@(self.bytesPublished),
            @"lastWidth":@(self.lastWidth), @"lastHeight":@(self.lastHeight),
            @"targetFPS":@10, @"jpegQuality":@.72, @"startedAt":@(self.startedAt),
            @"lastFrameAt":@(self.lastFrameAt), @"pinRequired":@YES };
    }
}

- (void)dealloc { [self stop]; }

@end
