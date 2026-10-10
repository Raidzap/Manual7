#import <Foundation/Foundation.h>
#import "../iOS/M7WebcamServer.h"
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#include <assert.h>
#include <errno.h>
#include <string.h>

static int ConnectUnix(NSString *path) {
    int client = socket(AF_UNIX, SOCK_STREAM, 0); assert(client >= 0);
    struct sockaddr_un address = {0};
    address.sun_len = sizeof(address); address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path)-1);
    assert(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0);
    struct timeval timeout = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    return client;
}

static void SendRequest(int client, NSString *request) {
    NSData *data = [request dataUsingEncoding:NSUTF8StringEncoding];
    assert(send(client, data.bytes, data.length, 0) == (ssize_t)data.length);
}

static NSData *ReadAvailable(int client) {
    NSMutableData *data = [NSMutableData new];
    uint8_t bytes[4096]; ssize_t count = 0;
    while ((count = recv(client, bytes, sizeof(bytes), 0)) > 0)
        [data appendBytes:bytes length:(NSUInteger)count];
    return data;
}

int main(void) {
    @autoreleasepool {
        NSString *path = [NSString stringWithFormat:@"/tmp/M7-webcam-%d.sock", getpid()];
        M7WebcamServer *server = [[M7WebcamServer alloc] initWithUnixSocketPath:path pin:@"123456"];
        NSError *error = nil;
        assert([server start:&error] && !error && server.running);
        struct stat info = {0}; assert(lstat(path.fileSystemRepresentation, &info) == 0);
        assert((info.st_mode & 0777) == 0600);

        int denied = ConnectUnix(path);
        SendRequest(denied, @"GET /v1/webcam.mjpg HTTP/1.1\r\nHost: localhost\r\n\r\n");
        NSData *deniedData = ReadAvailable(denied); close(denied);
        NSString *deniedText = [[NSString alloc] initWithData:deniedData encoding:NSUTF8StringEncoding];
        assert([deniedText containsString:@"401 Unauthorized"]);

        int client = ConnectUnix(path);
        SendRequest(client, @"GET /v1/webcam.mjpg HTTP/1.1\r\nHost: localhost\r\nX-Manual7-PIN: 123456\r\n\r\n");
        for (NSUInteger retry = 0; retry < 100 && server.clientCount != 1; ++retry) usleep(10000);
        assert(server.clientCount == 1);
        const uint8_t jpegBytes[] = {0xff, 0xd8, 0x01, 0x02, 0x03, 0xff, 0xd9};
        NSData *jpeg = [NSData dataWithBytes:jpegBytes length:sizeof(jpegBytes)];
        [server publishJPEG:jpeg width:1280 height:720];
        NSData *stream = ReadAvailable(client); close(client);
        NSData *status = [@"HTTP/1.1 200 OK" dataUsingEncoding:NSUTF8StringEncoding];
        NSData *boundary = [@"--m7frame" dataUsingEncoding:NSUTF8StringEncoding];
        assert([stream rangeOfData:status options:0 range:NSMakeRange(0, stream.length)].location != NSNotFound);
        assert([stream rangeOfData:boundary options:0 range:NSMakeRange(0, stream.length)].location != NSNotFound);
        assert([stream rangeOfData:jpeg options:0 range:NSMakeRange(0, stream.length)].location != NSNotFound);
        for (NSUInteger retry = 0; retry < 100 && [server.snapshot[@"framesPublished"] integerValue] != 1; ++retry)
            usleep(10000);
        NSDictionary *snapshot = server.snapshot;
        assert([snapshot[@"framesPublished"] integerValue] == 1);
        assert([snapshot[@"framesSubmitted"] integerValue] >= 1);
        assert([snapshot[@"framesCoalesced"] integerValue] <= [snapshot[@"framesSubmitted"] integerValue]);
        assert([snapshot[@"targetFPS"] integerValue] == 30);
        assert([snapshot[@"maxPendingFrames"] integerValue] == 1);
        assert([snapshot[@"lastFrameBytes"] integerValue] == (NSInteger)jpeg.length);
        assert([snapshot[@"clientsAccepted"] integerValue] == 1);
        assert([snapshot[@"clientsRejected"] integerValue] == 1);
        assert([snapshot[@"lastWidth"] integerValue] == 1280);
        assert([snapshot[@"lastHeight"] integerValue] == 720);
        assert([snapshot[@"unixSocketPermissions"] isEqual:@"0600"]);
        [server stop]; assert(!server.running);
        assert(lstat(path.fileSystemRepresentation, &info) != 0 && errno == ENOENT);
        puts("Webcam server: Unix socket, 0600, PIN, multipart MJPEG, counters and cleanup passed.");
    }
    return 0;
}
