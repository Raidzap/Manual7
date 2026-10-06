#import <Foundation/Foundation.h>
#import "../iOS/M7OpenSSHStatus.h"
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>
#include <assert.h>

static void Write(NSString *path) {
    assert([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil]);
    assert([@"fixture" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]);
}

int main(void) {
    @autoreleasepool {
        NSString *prefix = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"M7-OpenSSH-%@", NSUUID.UUID.UUIDString]];
        NSString *binary = [prefix stringByAppendingPathComponent:@"usr/sbin/sshd"];
        Write(binary); assert(chmod(binary.fileSystemRepresentation, 0755) == 0);
        Write([prefix stringByAppendingPathComponent:@"Library/LaunchDaemons/com.openssh.sshd.plist"]);
        Write([prefix stringByAppendingPathComponent:@"etc/ssh/sshd_config"]);
        Write([prefix stringByAppendingPathComponent:@"etc/ssh/ssh_host_ed25519_key"]);

        int listener = socket(AF_INET, SOCK_STREAM, 0); assert(listener >= 0);
        struct sockaddr_in address = {0};
        address.sin_len = sizeof(address); address.sin_family = AF_INET;
        address.sin_port = 0; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0);
        assert(listen(listener, 1) == 0);
        socklen_t length = sizeof(address);
        assert(getsockname(listener, (struct sockaddr *)&address, &length) == 0);
        NSNumber *port = @(ntohs(address.sin_port));

        NSDictionary *status = M7OpenSSHStatusForPrefix(prefix, @[port]);
        assert([status[@"installed"] boolValue]);
        assert([status[@"configurationPresent"] boolValue]);
        assert([status[@"hostKeyCount"] integerValue] == 1);
        assert([status[@"serviceReachable"] boolValue]);
        assert([status[@"preferredPort"] isEqual:port]);
        assert([status[@"openPorts"] isEqual:@[port]]);
        assert([NSJSONSerialization isValidJSONObject:status]);

        close(listener);
        assert([NSFileManager.defaultManager removeItemAtPath:prefix error:nil]);
        NSDictionary *missing = M7OpenSSHStatusForPrefix(prefix, @[]);
        assert(![missing[@"installed"] boolValue] && ![missing[@"serviceReachable"] boolValue]);
        puts("OpenSSH status: package files, host keys, listening port and missing install passed.");
    }
    return 0;
}
