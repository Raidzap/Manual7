#import <Foundation/Foundation.h>
#import "../iOS/M7RemoteServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <sys/un.h>
#import <unistd.h>
#include <assert.h>
#include <errno.h>
#include <string.h>

static NSString *ReadResponse(int client, NSString *request) {
    NSData *data = [request dataUsingEncoding:NSUTF8StringEncoding];
    assert(send(client, data.bytes, data.length, 0) == (ssize_t)data.length);
    NSMutableData *response = [NSMutableData new];
    uint8_t buffer[4096]; ssize_t count = 0;
    while ((count = recv(client, buffer, sizeof(buffer), 0)) > 0)
        [response appendBytes:buffer length:(NSUInteger)count];
    close(client);
    return [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
}

static NSString *SendTCP(uint16_t port, NSString *request) {
    int client = socket(AF_INET, SOCK_STREAM, 0); assert(client >= 0);
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_port = htons(port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0);
    return ReadResponse(client, request);
}

static NSString *SendUnix(NSString *path, NSString *request) {
    int client = socket(AF_UNIX, SOCK_STREAM, 0); assert(client >= 0);
    struct sockaddr_un address = {0};
    address.sun_len = sizeof(address); address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path.fileSystemRepresentation, sizeof(address.sun_path)-1);
    assert(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0);
    return ReadResponse(client, request);
}

static NSString *POST(NSString *path, NSString *pin, NSString *json) {
    NSData *body = [json dataUsingEncoding:NSUTF8StringEncoding];
    return [NSString stringWithFormat:@"POST %@ HTTP/1.1\r\nHost: localhost\r\nX-Manual7-PIN: %@\r\nContent-Type: application/json\r\nContent-Length: %lu\r\n\r\n%@",
        path, pin, (unsigned long)body.length, json];
}

int main(void) {
    @autoreleasepool {
        __block NSUInteger handled = 0;
        M7RemoteServer *server = [[M7RemoteServer alloc] initWithPort:0 pin:@"123456"
            handler:^(NSDictionary *request, M7RemoteResponse response) {
                ++handled;
                if ([request[@"path"] isEqual:@"/v1/state"]) {
                    response(200, @{@"ok":@YES, @"mode":@"photo"});
                } else if ([request[@"path"] isEqual:@"/v1/command"]) {
                    assert([request[@"body"][@"command"] isEqual:@"capture"]);
                    response(202, @{@"ok":@YES, @"accepted":@YES});
                } else response(404, @{@"ok":@NO});
            }];
        NSError *error = nil;
        assert([server start:&error] && !error && server.port > 0 && server.running);

        NSString *ping = SendTCP(server.port, @"GET /v1/ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert([ping containsString:@"200 OK"] && [ping containsString:@"Manual7"]);
        NSString *denied = SendTCP(server.port, @"GET /v1/state HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert([denied containsString:@"401 Unauthorized"]);
        NSString *state = SendTCP(server.port,
            @"GET /v1/state HTTP/1.1\r\nHost: localhost\r\nX-Manual7-PIN: 123456\r\n\r\n");
        assert([state containsString:@"200 OK"] && [state containsString:@"photo"]);
        NSString *command = SendTCP(server.port, POST(@"/v1/command", @"123456", @"{\"command\":\"capture\"}"));
        assert([command containsString:@"202 Accepted"] && [command containsString:@"accepted"]);
        NSString *invalid = SendTCP(server.port, POST(@"/v1/command", @"123456", @"[invalid"));
        assert([invalid containsString:@"400 Bad Request"]);

        NSDictionary *snapshot = server.snapshot;
        assert([snapshot[@"acceptedRequests"] integerValue] == 4);
        assert([snapshot[@"rejectedRequests"] integerValue] == 1);
        assert([snapshot[@"malformedRequests"] integerValue] == 1);
        assert(handled == 2);
        [server stop]; assert(!server.running);

        NSString *socketPath = [NSString stringWithFormat:@"/tmp/M7-%d.sock", getpid()];
        M7RemoteServer *unixServer = [[M7RemoteServer alloc] initWithUnixSocketPath:socketPath
            pin:@"123456" handler:^(NSDictionary *request, M7RemoteResponse response) {
                ++handled;
                response(200, @{ @"ok":@YES, @"path":request[@"path"] ?: @"" });
            }];
        error = nil;
        assert([unixServer start:&error] && !error && unixServer.running && unixServer.port == 0);
        struct stat info = {0}; assert(lstat(socketPath.fileSystemRepresentation, &info) == 0);
        assert((info.st_mode & 0777) == 0600);
        NSString *unixPing = SendUnix(socketPath,
            @"GET /v1/ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert([unixPing containsString:@"200 OK"] && [unixPing containsString:@"unix"]);
        NSString *unixState = SendUnix(socketPath,
            @"GET /v1/state HTTP/1.1\r\nHost: localhost\r\nX-Manual7-PIN: 123456\r\n\r\n");
        // NSJSONSerialization may escape slashes as `\/`; verify the routed key
        // and status instead of depending on one valid JSON spelling.
        assert([unixState containsString:@"200 OK"] && [unixState containsString:@"\"path\""]);
        NSDictionary *unixSnapshot = unixServer.snapshot;
        assert([unixSnapshot[@"transport"] isEqual:@"unix"]);
        assert([unixSnapshot[@"unixSocketPath"] isEqual:socketPath]);
        assert([unixSnapshot[@"unixSocketExists"] boolValue]);
        assert([unixSnapshot[@"unixSocketPermissions"] isEqual:@"0600"]);
        assert(handled == 3);
        [unixServer stop]; assert(!unixServer.running);
        assert(lstat(socketPath.fileSystemRepresentation, &info) != 0 && errno == ENOENT);
        puts("Remote server: TCP/Unix bind, 0600 permissions, PIN, JSON routing, counters and cleanup passed.");
    }
    return 0;
}
