#import <Foundation/Foundation.h>
#import "../iOS/M7RemoteServer.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#include <assert.h>

static NSString *Send(uint16_t port, NSString *request) {
    int client = socket(AF_INET, SOCK_STREAM, 0); assert(client >= 0);
    struct sockaddr_in address = {0};
    address.sin_len = sizeof(address); address.sin_family = AF_INET;
    address.sin_port = htons(port); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(connect(client, (struct sockaddr *)&address, sizeof(address)) == 0);
    NSData *data = [request dataUsingEncoding:NSUTF8StringEncoding];
    assert(send(client, data.bytes, data.length, 0) == (ssize_t)data.length);
    NSMutableData *response = [NSMutableData new];
    uint8_t buffer[4096]; ssize_t count = 0;
    while ((count = recv(client, buffer, sizeof(buffer), 0)) > 0)
        [response appendBytes:buffer length:(NSUInteger)count];
    close(client);
    return [[NSString alloc] initWithData:response encoding:NSUTF8StringEncoding];
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

        NSString *ping = Send(server.port, @"GET /v1/ping HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert([ping containsString:@"200 OK"] && [ping containsString:@"Manual7"]);
        NSString *denied = Send(server.port, @"GET /v1/state HTTP/1.1\r\nHost: localhost\r\n\r\n");
        assert([denied containsString:@"401 Unauthorized"]);
        NSString *state = Send(server.port,
            @"GET /v1/state HTTP/1.1\r\nHost: localhost\r\nX-Manual7-PIN: 123456\r\n\r\n");
        assert([state containsString:@"200 OK"] && [state containsString:@"photo"]);
        NSString *command = Send(server.port, POST(@"/v1/command", @"123456", @"{\"command\":\"capture\"}"));
        assert([command containsString:@"202 Accepted"] && [command containsString:@"accepted"]);
        NSString *invalid = Send(server.port, POST(@"/v1/command", @"123456", @"[invalid"));
        assert([invalid containsString:@"400 Bad Request"]);

        NSDictionary *snapshot = server.snapshot;
        assert([snapshot[@"acceptedRequests"] integerValue] == 4);
        assert([snapshot[@"rejectedRequests"] integerValue] == 1);
        assert([snapshot[@"malformedRequests"] integerValue] == 1);
        assert(handled == 2);
        [server stop]; assert(!server.running);
        puts("Remote server: loopback bind, PIN, JSON routing, counters and shutdown passed.");
    }
    return 0;
}
