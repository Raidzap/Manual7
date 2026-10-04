#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <substrate.h>
#import "iOS/M7CameraController.h"

// Only public selectors are hooked. Native capture sessions remain intact.
static void (*M7OriginalStart)(AVCaptureSession *, SEL);
static void (*M7OriginalStop)(AVCaptureSession *, SEL);
static NSRecursiveLock *M7OwnershipLock;
static NSMapTable<AVCaptureSession *, NSNumber *> *M7HostSessions;
static BOOL M7OwnsCamera;
static char M7OwnedKey;
static UIButton *M7LaunchButton;

void M7MarkSessionOwned(AVCaptureSession *session) {
    objc_setAssociatedObject(session, &M7OwnedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void M7Start(AVCaptureSession *session, SEL selector) {
    if (objc_getAssociatedObject(session, &M7OwnedKey)) {
        M7OriginalStart(session, selector); return;
    }
    [M7OwnershipLock lock];
    @try {
        [M7HostSessions setObject:@YES forKey:session];
        if (!M7OwnsCamera) M7OriginalStart(session, selector);
    } @finally { [M7OwnershipLock unlock]; }
}

static void M7Stop(AVCaptureSession *session, SEL selector) {
    if (objc_getAssociatedObject(session, &M7OwnedKey)) {
        M7OriginalStop(session, selector); return;
    }
    [M7OwnershipLock lock];
    @try {
        [M7HostSessions setObject:@NO forKey:session];
        M7OriginalStop(session, selector);
    } @finally { [M7OwnershipLock unlock]; }
}

void M7BeginCameraOwnership(void) {
    [M7OwnershipLock lock];
    @try {
        M7OwnsCamera = YES;
        for (AVCaptureSession *session in M7HostSessions.keyEnumerator.allObjects) {
            if (session.isRunning) M7OriginalStop(session, @selector(stopRunning));
        }
    } @finally { [M7OwnershipLock unlock]; }
}

void M7EndCameraOwnership(BOOL foreground) {
    [M7OwnershipLock lock];
    @try {
        M7OwnsCamera = NO;
        if (foreground) {
            for (AVCaptureSession *session in M7HostSessions.keyEnumerator.allObjects) {
                if ([[M7HostSessions objectForKey:session] boolValue] && !session.isRunning)
                    M7OriginalStart(session, @selector(startRunning));
            }
        }
    } @finally { [M7OwnershipLock unlock]; }
}

@interface M7Launcher : NSObject
+ (void)install;
+ (void)open;
@end

@implementation M7Launcher
+ (UIWindow *)cameraWindow {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal) return window;
        }
    }
    return nil;
}
+ (void)install {
    UIWindow *window = [self cameraWindow];
    if (!window || M7LaunchButton.superview == window) return;
    [M7LaunchButton removeFromSuperview];
    M7LaunchButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [M7LaunchButton setTitle:@"M7" forState:UIControlStateNormal];
    M7LaunchButton.accessibilityLabel = @"Abrir câmera manual Manual7";
    M7LaunchButton.backgroundColor = [UIColor colorWithWhite:0 alpha:.8];
    M7LaunchButton.tintColor = UIColor.systemYellowColor;
    M7LaunchButton.layer.cornerRadius = 22;
    M7LaunchButton.translatesAutoresizingMaskIntoConstraints = NO;
    [M7LaunchButton addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];
    [window addSubview:M7LaunchButton];
    [NSLayoutConstraint activateConstraints:@[
        [M7LaunchButton.leadingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.leadingAnchor constant:12],
        [M7LaunchButton.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:54],
        [M7LaunchButton.widthAnchor constraintEqualToConstant:44],
        [M7LaunchButton.heightAnchor constraintEqualToConstant:44]]];
}
+ (void)open {
    if (!UIApplication.sharedApplication.isProtectedDataAvailable) return;
    UIViewController *top = [self cameraWindow].rootViewController;
    while (top.presentedViewController) {
        if ([top isKindOfClass:M7CameraController.class]) return;
        top = top.presentedViewController;
    }
    if (!top || [top isKindOfClass:M7CameraController.class]) return;
    M7CameraController *controller = [M7CameraController new];
    controller.modalPresentationStyle = UIModalPresentationFullScreen;
    [top presentViewController:controller animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void M7Initialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.camera"]) return;
        M7OwnershipLock = [NSRecursiveLock new];
        M7HostSessions = [NSMapTable weakToStrongObjectsMapTable];
        MSHookMessageEx(AVCaptureSession.class, @selector(startRunning), (IMP)M7Start, (IMP *)&M7OriginalStart);
        MSHookMessageEx(AVCaptureSession.class, @selector(stopRunning), (IMP)M7Stop, (IMP *)&M7OriginalStop);
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSNotificationName name in @[UIWindowDidBecomeKeyNotification,
                                               UIApplicationDidBecomeActiveNotification]) {
                [NSNotificationCenter.defaultCenter addObserverForName:name object:nil
                    queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                        [M7Launcher install];
                    }];
            }
            [M7Launcher install];
        });
    }
}
