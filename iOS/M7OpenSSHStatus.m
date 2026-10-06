#import "M7OpenSSHStatus.h"
#import <arpa/inet.h>
#import <errno.h>
#import <fcntl.h>
#import <netinet/in.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

static BOOL M7OpenSSHPortReachable(uint16_t port) {
    int client = socket(AF_INET, SOCK_STREAM, 0);
    if (client < 0) return NO;
    int flags = fcntl(client, F_GETFL, 0);
    if (flags >= 0) fcntl(client, F_SETFL, flags | O_NONBLOCK);
    struct sockaddr_in address = {0};
#if defined(__APPLE__)
    address.sin_len = sizeof(address);
#endif
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = connect(client, (struct sockaddr *)&address, sizeof(address));
    if (result < 0 && errno == EINPROGRESS) {
        struct pollfd descriptor = { .fd = client, .events = POLLOUT, .revents = 0 };
        result = poll(&descriptor, 1, 150);
        if (result > 0) {
            int error = 0;
            socklen_t length = sizeof(error);
            result = getsockopt(client, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0 ? 0 : -1;
        } else result = -1;
    }
    close(client);
    return result == 0;
}

NSDictionary *M7OpenSSHStatusForPrefix(NSString *prefix, NSArray<NSNumber *> *ports) {
    NSFileManager *manager = NSFileManager.defaultManager;
    NSString *binary = [prefix stringByAppendingPathComponent:@"usr/sbin/sshd"];
    NSString *launchDaemon = [prefix stringByAppendingPathComponent:
        @"Library/LaunchDaemons/com.openssh.sshd.plist"];
    NSString *configuration = [prefix stringByAppendingPathComponent:@"etc/ssh/sshd_config"];
    BOOL binaryPresent = [manager isExecutableFileAtPath:binary];
    BOOL launchDaemonPresent = [manager fileExistsAtPath:launchDaemon];
    BOOL configurationPresent = [manager fileExistsAtPath:configuration];
    NSUInteger hostKeyCount = 0;
    for (NSString *name in @[@"ssh_host_ed25519_key", @"ssh_host_ecdsa_key",
                              @"ssh_host_rsa_key", @"ssh_host_dsa_key"]) {
        NSString *path = [[prefix stringByAppendingPathComponent:@"etc/ssh"]
            stringByAppendingPathComponent:name];
        if ([manager fileExistsAtPath:path]) ++hostKeyCount;
    }
    NSMutableArray<NSNumber *> *openPorts = [NSMutableArray new];
    for (NSNumber *number in ports) {
        NSInteger value = number.integerValue;
        if (value > 0 && value <= UINT16_MAX && M7OpenSSHPortReachable((uint16_t)value))
            [openPorts addObject:@(value)];
    }
    NSNumber *preferredPort = openPorts.firstObject ?: @0;
    return @{ @"provider":@"Procursus", @"prefix":prefix,
        @"package":@"openssh-server", @"binaryPresent":@(binaryPresent),
        @"launchDaemonPresent":@(launchDaemonPresent),
        @"configurationPresent":@(configurationPresent),
        @"installed":@(binaryPresent && launchDaemonPresent),
        @"hostKeyCount":@(hostKeyCount), @"hostKeysReady":@(hostKeyCount > 0),
        @"checkedPorts":ports, @"openPorts":openPorts,
        @"serviceReachable":@(openPorts.count > 0), @"preferredPort":preferredPort,
        @"checkedAt":@(NSDate.date.timeIntervalSince1970) };
}

NSDictionary *M7OpenSSHStatus(void) {
    return M7OpenSSHStatusForPrefix(@"/var/jb", @[@22, @2222]);
}
