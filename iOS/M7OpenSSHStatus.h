#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Reports the Procursus OpenSSH installation and the loopback ports exposed by
// its launchd socket. This never starts a process or reads key contents.
FOUNDATION_EXPORT NSDictionary *M7OpenSSHStatus(void);

// Testable variant used by the macOS native suite.
FOUNDATION_EXPORT NSDictionary *M7OpenSSHStatusForPrefix(NSString *prefix,
    NSArray<NSNumber *> *ports);

NS_ASSUME_NONNULL_END
