#import "M7WebcamServer.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <netinet/tcp.h>
#import <poll.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/time.h>
#import <sys/un.h>
#import <unistd.h>

static const void *M7WebcamSendQueueKey = &M7WebcamSendQueueKey;
static const int M7WebcamBridgeConnectTimeoutMilliseconds = 250;
static const char M7WebcamBridgeActivation[] = "M7-BRIDGE-CLIENT-1\n";
static const NSUInteger M7WebcamTargetFPS = M7_WEBCAM_TARGET_FPS;
static const double M7WebcamJPEGQuality = M7_WEBCAM_JPEG_QUALITY;
// About 2 s of 1080x1920 H.264; past this the queue restarts at a keyframe.
static const NSUInteger M7WebcamMaxPendingH264Bytes = 2 * 1024 * 1024;

static void M7WebcamTuneSocket(int socketFD) {
    int enabled = 1;
    int bufferSize = 256 * 1024;
    setsockopt(socketFD, IPPROTO_TCP, TCP_NODELAY, &enabled, sizeof(enabled));
    setsockopt(socketFD, SOL_SOCKET, SO_SNDBUF, &bufferSize, sizeof(bufferSize));
    setsockopt(socketFD, SOL_SOCKET, SO_RCVBUF, &bufferSize, sizeof(bufferSize));
    struct timeval timeout = {.tv_sec = 1, .tv_usec = 0};
    setsockopt(socketFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static int M7WebcamConnectLoopback(int socketFD, const struct sockaddr_in *address) {
    int flags = fcntl(socketFD, F_GETFL, 0);
    if (flags < 0 || fcntl(socketFD, F_SETFL, flags | O_NONBLOCK) != 0) return -1;
    int result = connect(socketFD, (const struct sockaddr *)address, sizeof(*address));
    if (result != 0 && errno != EINPROGRESS) return -1;
    if (result != 0) {
        struct pollfd descriptor = {.fd = socketFD, .events = POLLOUT};
        do result = poll(&descriptor, 1, M7WebcamBridgeConnectTimeoutMilliseconds);
        while (result < 0 && errno == EINTR);
        if (result <= 0) { errno = result == 0 ? ETIMEDOUT : errno; return -1; }
        int code = 0; socklen_t length = sizeof(code);
        if (getsockopt(socketFD, SOL_SOCKET, SO_ERROR, &code, &length) != 0 || code != 0) {
            if (code) errno = code;
            return -1;
        }
    }
    return fcntl(socketFD, F_SETFL, flags);
}

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

@interface M7WebcamClient : NSObject
@property (nonatomic) int socket;
@property (nonatomic) M7WebcamCodec codec;
// H.264 clients start, and restart after a queue overflow, at a keyframe.
@property (nonatomic) BOOL waitingKeyframe;
@end

@implementation M7WebcamClient
@end

@interface M7WebcamFrame : NSObject
@property (nonatomic) NSData *data;
@property (nonatomic) M7WebcamCodec codec;
@property (nonatomic) BOOL keyframe;
@property (nonatomic) NSUInteger width;
@property (nonatomic) NSUInteger height;
@end

@implementation M7WebcamFrame
@end

@interface M7WebcamServer ()
@property (nonatomic) NSString *path;
@property (nonatomic) NSString *pin;
@property (nonatomic) dispatch_queue_t acceptQueue;
@property (nonatomic) dispatch_queue_t sendQueue;
@property (nonatomic) int listeningSocket;
@property (nonatomic) NSMutableDictionary<NSNumber *, M7WebcamClient *> *clients;
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
@property (nonatomic) uint16_t bridgePort;
@property (nonatomic) NSData *bridgeMagic;
@property (nonatomic) NSMutableSet<NSNumber *> *pendingBridgeSockets;
@property (nonatomic) BOOL ownsSocketPath;
@property (nonatomic) NSString *transport;
@property (nonatomic) BOOL sendInProgress;
@property (nonatomic) NSMutableArray<M7WebcamFrame *> *pendingFrames;
@property (nonatomic) BOOL keyframeRequested;
@property (nonatomic) NSUInteger h264FramesPublished;
@property (nonatomic) NSUInteger h264KeyframesPublished;
@property (nonatomic) NSUInteger h264QueueOverflows;
@property (nonatomic) NSUInteger h264FramesSkipped;
@property (nonatomic) NSUInteger framesSubmitted;
@property (nonatomic) NSUInteger framesCoalesced;
@property (nonatomic) NSUInteger lastFrameBytes;
@property (nonatomic) NSTimeInterval firstFrameAt;
@end

@implementation M7WebcamServer

- (instancetype)initWithUnixSocketPath:(NSString *)path pin:(NSString *)pin {
    if ((self = [super init])) {
        _path = [path copy]; _pin = [pin copy];
        _acceptQueue = dispatch_queue_create("dev.manual7.webcam.accept", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("dev.manual7.webcam.send", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_sendQueue, M7WebcamSendQueueKey,
            (void *)M7WebcamSendQueueKey, NULL);
        _listeningSocket = -1; _clients = [NSMutableDictionary new];
        _pendingFrames = [NSMutableArray new];
        _pendingBridgeSockets = [NSMutableSet new]; _transport = @"multipart-mjpeg-unix";
    }
    return self;
}

- (instancetype)initWithBridgePort:(uint16_t)bridgePort publicUnixSocketPath:(NSString *)path
    magic:(NSString *)magic pin:(NSString *)pin {
    if ((self = [super init])) {
        _path = [path copy]; _pin = [pin copy]; _bridgePort = bridgePort;
        _bridgeMagic = [magic dataUsingEncoding:NSUTF8StringEncoding];
        _transport = @"multipart-mjpeg-launchd-bridge-unix";
        _acceptQueue = dispatch_queue_create("dev.manual7.webcam.bridge", DISPATCH_QUEUE_SERIAL);
        _sendQueue = dispatch_queue_create("dev.manual7.webcam.send", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_sendQueue, M7WebcamSendQueueKey,
            (void *)M7WebcamSendQueueKey, NULL);
        _listeningSocket = -1; _clients = [NSMutableDictionary new];
        _pendingFrames = [NSMutableArray new];
        _pendingBridgeSockets = [NSMutableSet new];
    }
    return self;
}

- (int)newBridgeSocket:(NSError **)error {
    int client = socket(AF_INET, SOCK_STREAM, 0);
    if (client < 0) {
        if (error) *error = M7WebcamSocketError(errno, @"socket(AF_INET bridge)",
            @"Não foi possível criar a conexão da webcam com o serviço auxiliar.");
        return -1;
    }
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
#endif
    M7WebcamTuneSocket(client);
    struct sockaddr_in address = {0};
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(self.bridgePort);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (M7WebcamConnectLoopback(client, &address) != 0) {
        NSInteger code = errno; close(client);
        if (error) *error = M7WebcamSocketError(code, @"connect(launchd bridge)",
            @"O serviço auxiliar da webcam não respondeu.");
        return -1;
    }
    if (!M7WebcamSendAll(client, self.bridgeMagic)) {
        NSInteger code = errno ?: EPIPE; close(client);
        if (error) *error = M7WebcamSocketError(code, @"authenticate(launchd bridge)",
            @"O serviço auxiliar recusou a conexão da webcam.");
        return -1;
    }
    return client;
}

- (void)runBridgeWorker:(int)initialSocket generation:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.acceptQueue, ^{
        int client = initialSocket;
        while (YES) {
            M7WebcamServer *owner = weakSelf;
            if (!owner) { if (client >= 0) close(client); break; }
            @synchronized (owner) {
                if (!owner.running || owner.generation != generation) {
                    if (client >= 0) close(client);
                    break;
                }
            }
            if (client < 0) {
                client = [owner newBridgeSocket:nil];
                if (client < 0) { usleep(1000000); continue; }
            }
            @synchronized (owner) { [owner.pendingBridgeSockets addObject:@(client)]; }
            uint8_t activation[sizeof(M7WebcamBridgeActivation) - 1] = {0};
            NSUInteger received = 0;
            while (received < sizeof(activation)) {
                ssize_t count = recv(client, activation + received, sizeof(activation) - received, 0);
                if (count < 0 && errno == EINTR) continue;
                if (count <= 0) break;
                received += (NSUInteger)count;
            }
            if (received == sizeof(activation) &&
                memcmp(activation, M7WebcamBridgeActivation, sizeof(activation)) == 0) {
                // Idle workers wait indefinitely for activation; once a client is
                // attached, a missing request must not hold this serial worker.
                struct timeval receiveTimeout = {.tv_sec = 3, .tv_usec = 0};
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
                [owner handleClient:client generation:generation];
            } else close(client);
            @synchronized (owner) { [owner.pendingBridgeSockets removeObject:@(client)]; }
            client = -1;
        }
    });
}

- (BOOL)startBridge:(NSError **)error {
    if (!self.bridgeMagic.length || !self.bridgePort) {
        if (error) *error = M7WebcamSocketError(EINVAL, @"bridge configuration",
            @"A configuração do serviço auxiliar da webcam é inválida.");
        return NO;
    }
    int first = [self newBridgeSocket:error];
    if (first < 0) return NO;
    self.running = YES;
    self.startedAt = NSDate.date.timeIntervalSince1970;
    NSUInteger generation = ++self.generation;
    [self runBridgeWorker:first generation:generation];
    return YES;
}

- (BOOL)start:(NSError **)error {
    @synchronized (self) {
        if (self.running) return YES;
        self.clientsAccepted = 0; self.clientsRejected = 0; self.clientsDropped = 0;
        self.framesSubmitted = 0; self.framesPublished = 0; self.framesCoalesced = 0;
        self.bytesPublished = 0; self.lastWidth = 0; self.lastHeight = 0;
        self.lastFrameBytes = 0; self.firstFrameAt = 0; self.lastFrameAt = 0;
        self.sendInProgress = NO; [self.pendingFrames removeAllObjects];
        self.keyframeRequested = NO; self.h264FramesPublished = 0; self.h264KeyframesPublished = 0;
        self.h264QueueOverflows = 0; self.h264FramesSkipped = 0;
        if (self.bridgePort) return [self startBridge:error];
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
        if (lstat(path, &info) == 0) {
            self.socketDevice = info.st_dev; self.socketInode = info.st_ino;
            self.ownsSocketPath = YES;
        }
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
        BOOL h264 = [lines.firstObject hasPrefix:@"GET /v1/webcam.h264 "];
        BOOL route = h264 || [lines.firstObject hasPrefix:@"GET /v1/webcam.mjpg "];
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
            M7WebcamClient *entry = [M7WebcamClient new];
            entry.socket = client;
            entry.codec = h264 ? M7WebcamCodecH264 : M7WebcamCodecMJPEG;
            entry.waitingKeyframe = h264;
            if (h264) self.keyframeRequested = YES;
            self.clients[@(client)] = entry; ++self.clientsAccepted;
        }
    }
}

- (NSUInteger)clientCount { @synchronized (self) { return self.clients.count; } }

- (NSUInteger)clientCountForCodec:(M7WebcamCodec)codec {
    @synchronized (self) {
        NSUInteger count = 0;
        for (M7WebcamClient *client in self.clients.allValues) if (client.codec == codec) ++count;
        return count;
    }
}

- (BOOL)consumeKeyframeRequest {
    @synchronized (self) {
        BOOL requested = self.keyframeRequested;
        self.keyframeRequested = NO;
        return requested;
    }
}

- (void)publishJPEG:(NSData *)jpeg width:(NSUInteger)width height:(NSUInteger)height {
    [self publishFrame:jpeg codec:M7WebcamCodecMJPEG keyframe:YES width:width height:height];
}

- (void)publishH264:(NSData *)accessUnit keyframe:(BOOL)keyframe
    width:(NSUInteger)width height:(NSUInteger)height {
    [self publishFrame:accessUnit codec:M7WebcamCodecH264 keyframe:keyframe width:width height:height];
}

// Caller holds the lock. JPEG keeps only the newest pending frame. H.264 cannot
// skip predicted frames, so it queues; on overflow it drops the queue and every
// H.264 client resumes at the next keyframe, which is requested at once.
- (void)enqueueFrame:(M7WebcamFrame *)frame {
    if (frame.codec == M7WebcamCodecMJPEG) {
        NSIndexSet *stale = [self.pendingFrames indexesOfObjectsPassingTest:
            ^BOOL(M7WebcamFrame *pending, __unused NSUInteger index, __unused BOOL *stop) {
                return pending.codec == M7WebcamCodecMJPEG; }];
        self.framesCoalesced += stale.count;
        [self.pendingFrames removeObjectsAtIndexes:stale];
        [self.pendingFrames addObject:frame];
        return;
    }
    NSUInteger pendingBytes = frame.data.length;
    for (M7WebcamFrame *pending in self.pendingFrames)
        if (pending.codec == M7WebcamCodecH264) pendingBytes += pending.data.length;
    if (pendingBytes > M7WebcamMaxPendingH264Bytes) {
        NSIndexSet *queued = [self.pendingFrames indexesOfObjectsPassingTest:
            ^BOOL(M7WebcamFrame *pending, __unused NSUInteger index, __unused BOOL *stop) {
                return pending.codec == M7WebcamCodecH264; }];
        self.h264FramesSkipped += queued.count;
        [self.pendingFrames removeObjectsAtIndexes:queued];
        for (M7WebcamClient *client in self.clients.allValues)
            if (client.codec == M7WebcamCodecH264) client.waitingKeyframe = YES;
        ++self.h264QueueOverflows;
        if (!frame.keyframe) { self.keyframeRequested = YES; ++self.h264FramesSkipped; return; }
    }
    [self.pendingFrames addObject:frame];
}

- (void)publishFrame:(NSData *)data codec:(M7WebcamCodec)codec keyframe:(BOOL)keyframe
    width:(NSUInteger)width height:(NSUInteger)height {
    if (!data.length) return;
    M7WebcamFrame *frame = [M7WebcamFrame new];
    frame.data = data; frame.codec = codec; frame.keyframe = keyframe;
    frame.width = width; frame.height = height;
    @synchronized (self) {
        if (!self.running || !self.clients.count) return;
        ++self.framesSubmitted;
        [self enqueueFrame:frame];
        if (self.sendInProgress) return;
        self.sendInProgress = YES;
    }
    dispatch_async(self.sendQueue, ^{ [self drainPendingFrames]; });
}

// sendQueue only.
- (void)drainPendingFrames {
    while (YES) {
        M7WebcamFrame *frame = nil;
        NSMutableArray<M7WebcamClient *> *targets = [NSMutableArray new];
        @synchronized (self) {
            if (!self.running || !self.clients.count || !self.pendingFrames.count) {
                [self.pendingFrames removeAllObjects];
                self.sendInProgress = NO;
                return;
            }
            frame = self.pendingFrames.firstObject;
            [self.pendingFrames removeObjectAtIndex:0];
            for (M7WebcamClient *client in self.clients.allValues) {
                if (client.codec != frame.codec) continue;
                if (client.waitingKeyframe) {
                    if (!frame.keyframe) continue;
                    client.waitingKeyframe = NO;
                }
                [targets addObject:client];
            }
        }
        if (!targets.count) continue;
        NSString *type = frame.codec == M7WebcamCodecH264 ? @"video/h264" : @"image/jpeg";
        NSString *keyframe = frame.codec == M7WebcamCodecH264 ?
            [NSString stringWithFormat:@"X-Keyframe: %d\r\n", frame.keyframe ? 1 : 0] : @"";
        NSString *head = [NSString stringWithFormat:
            @"--m7frame\r\nContent-Type: %@\r\nContent-Length: %lu\r\nX-Width: %lu\r\nX-Height: %lu\r\n%@X-Timestamp: %.6f\r\n\r\n",
            type, (unsigned long)frame.data.length, (unsigned long)frame.width,
            (unsigned long)frame.height, keyframe, NSDate.date.timeIntervalSince1970];
        NSMutableData *part = [[head dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        [part appendData:frame.data]; [part appendBytes:"\r\n" length:2];
        NSUInteger delivered = 0;
        for (M7WebcamClient *client in targets) {
            if (M7WebcamSendAll(client.socket, part)) { ++delivered; continue; }
            shutdown(client.socket, SHUT_RDWR); close(client.socket);
            @synchronized (self) { [self.clients removeObjectForKey:@(client.socket)]; ++self.clientsDropped; }
        }
        if (delivered) @synchronized (self) {
            NSTimeInterval timestamp = NSDate.date.timeIntervalSince1970;
            if (!self.firstFrameAt) self.firstFrameAt = timestamp;
            ++self.framesPublished; self.bytesPublished += frame.data.length * delivered;
            if (frame.codec == M7WebcamCodecH264) {
                ++self.h264FramesPublished;
                if (frame.keyframe) ++self.h264KeyframesPublished;
            }
            self.lastWidth = frame.width; self.lastHeight = frame.height;
            self.lastFrameBytes = frame.data.length;
            self.lastFrameAt = timestamp;
        }
    }
}

- (void)closeClientsForCodec:(M7WebcamCodec)codec {
    void (^closeMatching)(void) = ^{
        NSMutableArray<M7WebcamClient *> *closing = [NSMutableArray new];
        @synchronized (self) {
            for (M7WebcamClient *client in self.clients.allValues)
                if (client.codec == codec) [closing addObject:client];
            for (M7WebcamClient *client in closing) [self.clients removeObjectForKey:@(client.socket)];
        }
        for (M7WebcamClient *client in closing) { shutdown(client.socket, SHUT_RDWR); close(client.socket); }
    };
    // Sockets are only closed on sendQueue, never under an in-flight send.
    if (dispatch_get_specific(M7WebcamSendQueueKey)) closeMatching();
    else dispatch_async(self.sendQueue, closeMatching);
}

- (void)stop {
    int server = -1;
    @synchronized (self) {
        if (!self.running && self.listeningSocket < 0 && self.pendingBridgeSockets.count == 0) return;
        self.running = NO; ++self.generation; server = self.listeningSocket; self.listeningSocket = -1;
        [self.pendingFrames removeAllObjects];
        for (NSNumber *number in self.pendingBridgeSockets) shutdown(number.intValue, SHUT_RDWR);
        [self.pendingBridgeSockets removeAllObjects];
    }
    if (server >= 0) { shutdown(server, SHUT_RDWR); close(server); }
    void (^closeClients)(void) = ^{
        NSArray<NSNumber *> *clients = nil;
        @synchronized (self) { clients = self.clients.allKeys; [self.clients removeAllObjects]; }
        for (NSNumber *number in clients) { shutdown(number.intValue, SHUT_RDWR); close(number.intValue); }
    };
    if (dispatch_get_specific(M7WebcamSendQueueKey)) closeClients();
    else dispatch_sync(self.sendQueue, closeClients);
    struct stat info = {0};
    if (self.ownsSocketPath && lstat(self.path.fileSystemRepresentation, &info) == 0 &&
        info.st_dev == self.socketDevice && info.st_ino == self.socketInode)
        unlink(self.path.fileSystemRepresentation);
    self.ownsSocketPath = NO;
}

- (NSDictionary *)snapshot {
    @synchronized (self) {
        struct stat info = {0}; BOOL exists = lstat(self.path.fileSystemRepresentation, &info) == 0;
        NSTimeInterval duration = self.framesPublished > 1 ? self.lastFrameAt - self.firstFrameAt : 0;
        double effectiveFPS = duration > 0 ? (self.framesPublished - 1) / duration : 0;
        return @{ @"running":@(self.running), @"transport":self.transport ?: @"",
            @"unixSocketPath":self.path, @"unixSocketExists":@(exists),
            @"unixSocketPermissions":exists ? [NSString stringWithFormat:@"%04o",
                (unsigned int)(info.st_mode & 0777)] : @"",
            @"clientCount":@(self.clients.count), @"clientsAccepted":@(self.clientsAccepted),
            @"clientsRejected":@(self.clientsRejected), @"clientsDropped":@(self.clientsDropped),
            @"framesSubmitted":@(self.framesSubmitted), @"framesPublished":@(self.framesPublished),
            @"framesCoalesced":@(self.framesCoalesced), @"bytesPublished":@(self.bytesPublished),
            @"lastWidth":@(self.lastWidth), @"lastHeight":@(self.lastHeight),
            @"lastFrameBytes":@(self.lastFrameBytes), @"effectiveFPS":@(effectiveFPS),
            @"sendInProgress":@(self.sendInProgress), @"pendingLatestFrame":@(self.pendingFrames.count > 0),
            @"pendingFrames":@(self.pendingFrames.count), @"maxPendingFrames":@1,
            @"clientsByCodec":@{ @"mjpeg":@([self clientCountForCodec:M7WebcamCodecMJPEG]),
                @"h264":@([self clientCountForCodec:M7WebcamCodecH264]) },
            @"h264":@{ @"framesPublished":@(self.h264FramesPublished),
                @"keyframesPublished":@(self.h264KeyframesPublished),
                @"queueOverflows":@(self.h264QueueOverflows), @"framesSkipped":@(self.h264FramesSkipped),
                @"maxPendingBytes":@(M7WebcamMaxPendingH264Bytes) },
            @"targetFPS":@(M7WebcamTargetFPS), @"jpegQuality":@(M7WebcamJPEGQuality), @"startedAt":@(self.startedAt),
            @"lastFrameAt":@(self.lastFrameAt), @"pinRequired":@YES,
            @"bridgePort":@(self.bridgePort),
            @"pendingBridgeWorkers":@(self.pendingBridgeSockets.count) };
    }
}

- (void)dealloc { [self stop]; }

@end
