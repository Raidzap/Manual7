#import "M7CameraController.h"
#import "M7DeviceControls.h"
#import "M7RAWConfiguration.h"
#import "M7JPEG.h"
#import "M7Storage.h"
#import "M7ErrorDetails.h"
#import "M7CaptureResult.h"
#import "M7VideoRecorder.h"
#import "M7VideoReframe.h"
#import "M7SubjectTracker.h"
#import "M7RemoteServer.h"
#import "M7OpenSSHStatus.h"
#import "M7WebcamEncoder.h"
#import "M7WebcamServer.h"
#import "M7PairingManager.h"
#import "../Core/M7Math.h"
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <unistd.h>

// Preserve the explicit mode across M7 controllers in this Camera process.
static atomic_bool M7PhotoOnlyPreferred = ATOMIC_VAR_INIT(false);
// Immutable latest automatic report, retained across M7 controllers in this process.
static NSDictionary *M7LastTestReport;

static NSDictionary *M7JSONSnapshot(NSDictionary *value) {
    if (!value) return @{};
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : @{};
}

static NSDictionary *M7TrackingReport(NSArray<NSDictionary *> *points, NSDictionary *summary) {
    const NSUInteger maximum = 600;
    NSUInteger stride = MAX((NSUInteger)1, (points.count + maximum - 1) / maximum);
    NSMutableArray *sampled = [NSMutableArray new];
    for (NSUInteger index = 0; index < points.count; index += stride) [sampled addObject:points[index]];
    if (points.count && sampled.lastObject != points.lastObject) [sampled addObject:points.lastObject];
    return @{ @"enabled":@YES, @"detector":@"humanUpperBodyWithFaceFallback", @"analysisHz":@5,
        @"totalPoints":@(points.count), @"reportedPoints":@(sampled.count), @"reportStride":@(stride),
        @"summary":summary ?: @{}, @"points":sampled };
}

// IPv4 addresses and the API PIN stay masked on screen until tapped; a reveal
// lasts M7RevealSeconds. The QR payload and the network traffic are unchanged.
static NSString *const M7IPMask = @"•••.•••.•••.•••";
static NSString *const M7PINMask = @"••••••";
static const NSTimeInterval M7RevealSeconds = 10;

static NSString *M7RedactIPv4(NSString *text) {
    static NSRegularExpression *pattern;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        pattern = [NSRegularExpression regularExpressionWithPattern:
            @"\\b(?:(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1?\\d?\\d)\\b"
            options:0 error:nil];
    });
    if (!text.length) return @"";
    return [pattern stringByReplacingMatchesInString:text options:0
        range:NSMakeRange(0, text.length) withTemplate:M7IPMask];
}

// Own the encoded sensor output until Photos confirms saving it. A local
// backup is optional: Apple's Camera process need not have a Documents sandbox.
@interface M7Photo : NSObject
@property (nonatomic) NSString *filename;
@property (nonatomic) NSData *data;
@property (nonatomic) NSURL *file;
@property (nonatomic) int64_t captureID;
@end
@implementation M7Photo
@end

@interface M7CameraController () <M7RequiredPhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate>
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) dispatch_queue_t videoQueue;
@property (nonatomic) dispatch_queue_t trackingQueue;
@property (nonatomic) dispatch_queue_t webcamQueue;
@property (nonatomic) dispatch_queue_t pairingQueue;
@property (nonatomic) dispatch_queue_t remoteQueue;
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *input;
@property (nonatomic) AVCapturePhotoOutput *photoOutput;
@property (nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic) AVCaptureAudioDataOutput *audioOutput;
@property (nonatomic) AVCaptureDeviceInput *audioInput;
@property (nonatomic) M7DeviceControls *controls;
@property (nonatomic) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic) UIView *previewView;
@property (nonatomic) UIImageView *peakingView;
@property (nonatomic) CAShapeLayer *reframeGuideLayer;
@property (nonatomic) UILabel *readout;
@property (nonatomic) UILabel *status;
@property (nonatomic) UISlider *isoSlider;
@property (nonatomic) UISlider *shutterSlider;
@property (nonatomic) UISlider *focusSlider;
@property (nonatomic) UISlider *thresholdSlider;
@property (nonatomic) UIStepper *evStepper;
@property (nonatomic) UISegmentedControl *exposureMode;
@property (nonatomic) UISegmentedControl *focusMode;
@property (nonatomic) UISegmentedControl *lens;
@property (nonatomic) UISegmentedControl *captureMode;
@property (nonatomic) UISegmentedControl *videoFormat;
@property (nonatomic) UILabel *remoteLabel;
@property (nonatomic) UIButton *pairButton;
@property (nonatomic) UISwitch *webcamSwitch;
@property (nonatomic) UISegmentedControl *webcamFormat;
@property (nonatomic) UIView *rawRow;
@property (nonatomic) UIView *sizeRow;
@property (nonatomic) UIView *videoFormatRow;
@property (nonatomic) UIView *trackingRow;
@property (nonatomic) UISwitch *trackingSwitch;
@property (nonatomic) UISwitch *rawSwitch;
@property (nonatomic) UIButton *sizeButton;
@property (nonatomic) NSUInteger jpegLongEdge;
@property (nonatomic) NSUInteger captureLongEdge;
@property (nonatomic) BOOL captureAvailable;
@property (nonatomic) NSMutableDictionary *captureTrace;
@property (nonatomic) NSString *controllerID;
@property (nonatomic) NSString *sessionID;
@property (nonatomic) BOOL photoOnlyRequested;
@property (nonatomic) NSMutableDictionary *comparisonReport;
@property (nonatomic) BOOL comparisonActive;
@property (nonatomic) NSMutableArray *sessionEvents;
@property (nonatomic) M7Storage *storage;
@property (nonatomic) NSDictionary *lensDiagnostic;
@property (nonatomic) NSDictionary *videoFormatDiagnostic;
@property (nonatomic) NSMutableDictionary *videoTrace;
@property (nonatomic) NSMutableArray<NSDictionary *> *pendingVideos;
@property (nonatomic) M7VideoRecorder *videoRecorder;
@property (nonatomic) M7SubjectTracker *subjectTracker;
@property (nonatomic) M7RemoteServer *remoteServer;
@property (nonatomic) M7WebcamServer *webcamServer;
@property (nonatomic) M7WebcamEncoder *webcamEncoder;
@property (nonatomic) M7PairingManager *pairingManager;
@property (nonatomic) NSString *remotePIN;
@property (nonatomic) NSString *remoteSocketPath;
@property (nonatomic) NSString *webcamSocketPath;
@property (nonatomic) NSArray<NSDictionary *> *remoteBindAttempts;
@property (nonatomic) NSMutableArray<NSDictionary *> *remoteEvents;
@property (nonatomic) NSDictionary *openSSHStatus;
@property (nonatomic) NSDictionary *remoteStartup;
@property (atomic) BOOL remoteStarting;
@property (atomic) NSUInteger remoteGeneration;
@property (atomic) BOOL videoRecording;
@property (atomic) BOOL videoProcessing;
@property (atomic) BOOL videoModeActive;
@property (nonatomic) CFTimeInterval videoStartedAt;
@property (nonatomic) NSInteger activeVideoOutputMode;
@property (nonatomic) UIBackgroundTaskIdentifier videoBackgroundTask;
@property (nonatomic) NSURL *videoMasterURL;
@property (nonatomic) NSArray<NSNumber *> *videoFramesToExport;
@property (nonatomic) NSUInteger videoExportIndex;
@property (nonatomic) NSUInteger videoSavedCount;
@property (nonatomic) NSUInteger videoFailedCount;
@property (nonatomic) NSUInteger videoExportFailureCount;
@property (nonatomic) NSArray<NSDictionary *> *videoTrackingPoints;
@property (atomic) BOOL trackingEnabled;
@property (atomic) BOOL trackingPending;
@property (atomic) BOOL webcamEnabled;
@property (atomic) BOOL webcamEncoding;
@property (atomic) BOOL webcamVertical;
@property (atomic) BOOL webcamRequested;
@property (atomic) NSUInteger webcamInputFrames;
@property (atomic) NSUInteger webcamEncodedFrames;
@property (atomic) NSUInteger webcamBusyDrops;
@property (atomic) double webcamEncodeMillisecondsTotal;
@property (atomic) double webcamLastEncodeMilliseconds;
@property (atomic) BOOL webcamHoldsIdleTimer;
@property (atomic) NSUInteger webcamThermalDrops;
@property (atomic) M7CameraMount cameraMount;
@property (nonatomic) UISegmentedControl *mountControl;
@property (nonatomic) BOOL idleTimerWasDisabled;
@property (atomic) BOOL pairingScanning;
@property (atomic) BOOL pairingAnalyzing;
@property (atomic) BOOL pairingSubmitting;
@property (atomic) NSUInteger pairingGeneration;
@property (nonatomic) CFTimeInterval pairingStartedAt;
@property (nonatomic) CFTimeInterval lastPairingScanTime;
@property (atomic) NSDictionary *lastWebcamError;
@property (nonatomic) CFTimeInterval lastWebcamTime;
@property (nonatomic) CFTimeInterval lastWebcamErrorLogTime;
@property (nonatomic) CFTimeInterval lastTrackingTime;
@property (nonatomic) CFTimeInterval lastTrackingErrorLogTime;
@property (nonatomic) CGPoint trackingCenter;
@property (nonatomic) BOOL trackingDetected;
@property (nonatomic) NSMutableSet<NSString *> *photosInFlight;
@property (nonatomic) NSMutableSet<NSString *> *photosImported;
@property (nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *photoResults;
@property (nonatomic) M7Photo *pendingPhoto;
@property (nonatomic) UISwitch *peakingSwitch;
@property (nonatomic) UIButton *shutterButton;
@property (nonatomic) UIButton *shareButton;
@property (nonatomic) UIButton *closeButton;
@property (nonatomic) NSTimer *timer;
@property (nonatomic) NSArray *observers;
@property (nonatomic) NSURL *lastFile;
@property (nonatomic) NSDictionary *limits;
@property (atomic) BOOL configured;
@property (atomic) BOOL closing;
@property (nonatomic) BOOL startedSetup;
@property (nonatomic) BOOL captureBusy;
@property (atomic) BOOL rawCaptureWaiting;
@property (atomic) BOOL rawPreparationPending;
@property (nonatomic) BOOL rawPrepared;
@property (nonatomic) NSUInteger rawPreparationRevision;
@property (nonatomic) NSUInteger rawWaitGeneration;
@property (nonatomic) NSDictionary *rawPreparationReport;
@property (nonatomic) BOOL pendingExposure;
@property (nonatomic) BOOL pendingFocus;
@property (nonatomic) NSUInteger exposureRevision;
@property (nonatomic) NSUInteger focusRevision;
@property (nonatomic) int64_t captureID;
@property (nonatomic) NSData *captureData;
@property (nonatomic) NSDictionary *captureMetadata;
@property (nonatomic) NSError *captureError;
@property (nonatomic) M7CaptureResult *captureResult;
@property (nonatomic) BOOL captureRAW;
@property (atomic) BOOL peakingEnabled;
@property (atomic) double peakingThreshold;
@property (atomic) BOOL overlayPending;
@property (nonatomic) CFTimeInterval lastPeakingTime;
@property (nonatomic) CFTimeInterval lastFocusRequest;
@property (nonatomic, copy) NSString *statusText;
@property (nonatomic) BOOL statusRevealed;
@property (nonatomic, copy) NSString *remoteStatusText;
@property (nonatomic) BOOL remoteShowsPIN;
@property (nonatomic) BOOL pinRevealed;
@property (nonatomic) NSUInteger revealGeneration;
@property (nonatomic) UIView *focusIndicator;
@end

static NSString *const M7CameraMountDefaultsKey = @"dev.manual7.cameraMount";

static NSString *M7ThermalName(NSProcessInfoThermalState state) {
    switch (state) {
        case NSProcessInfoThermalStateFair: return @"fair";
        case NSProcessInfoThermalStateSerious: return @"serious";
        case NSProcessInfoThermalStateCritical: return @"critical";
        default: return @"nominal";
    }
}

// Webcam frame-rate cap while the A10 is hot; 0 means the camera's own 30 fps.
// iOS throttles the CPU/GPU itself at these levels, and fewer encoded frames
// lower the heat instead of letting the encoder fall behind.
static double M7ThermalMaxWebcamFPS(NSProcessInfoThermalState state) {
    return state >= NSProcessInfoThermalStateCritical ? 15 :
        state >= NSProcessInfoThermalStateSerious ? 20 : 0;
}

static NSString *M7CameraMountName(M7CameraMount mount) {
    return mount == M7CameraMountPortrait ? @"portrait" :
        mount == M7CameraMountLandscapeInverted ? @"landscapeInverted" : @"landscape";
}

static AVCaptureVideoOrientation M7VideoOrientationForMount(M7CameraMount mount) {
    return mount == M7CameraMountPortrait ? AVCaptureVideoOrientationPortrait :
        mount == M7CameraMountLandscapeInverted ? AVCaptureVideoOrientationLandscapeLeft :
        AVCaptureVideoOrientationLandscapeRight;
}

// Orientation that shows a buffer of `mount` upright in the portrait preview.
static UIImageOrientation M7PreviewImageOrientation(M7CameraMount mount) {
    return mount == M7CameraMountPortrait ? UIImageOrientationUp :
        mount == M7CameraMountLandscapeInverted ? UIImageOrientationLeft : UIImageOrientationRight;
}

@implementation M7CameraController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationPortrait; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (UIButton *)button:(NSString *)title action:(SEL)action {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.tintColor = UIColor.systemYellowColor;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return b;
}

- (UIStackView *)row:(NSString *)title control:(UIView *)control {
    UILabel *label = [UILabel new]; label.text = title;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:13];
    [label.widthAnchor constraintEqualToConstant:76].active = YES;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    row.spacing = 8; row.alignment = UIStackViewAlignmentCenter;
    [row.heightAnchor constraintGreaterThanOrEqualToConstant:44].active = YES;
    return row;
}

- (UILabel *)section:(NSString *)title {
    UILabel *label = [UILabel new];
    label.text = title.uppercaseString;
    label.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    label.textColor = [UIColor colorWithWhite:1 alpha:.5];
    label.accessibilityTraits = UIAccessibilityTraitHeader;
    [label.heightAnchor constraintEqualToConstant:30].active = YES;
    return label;
}

// UIStackView miscounts repeated identical hidden assignments, and the
// refresh timer calls this every 300 ms.
- (void)setRow:(UIView *)row hidden:(BOOL)hidden {
    if (row.hidden != hidden) row.hidden = hidden;
}

- (UISlider *)slider:(NSString *)label action:(SEL)action {
    UISlider *s = [UISlider new]; s.accessibilityLabel = label;
    s.tintColor = UIColor.systemYellowColor;
    // Apply on release to avoid queuing dozens of lens/exposure transitions.
    s.continuous = NO;
    [s addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return s;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.sessionQueue = dispatch_queue_create("dev.manual7.session", DISPATCH_QUEUE_SERIAL);
    self.videoQueue = dispatch_queue_create("dev.manual7.media", DISPATCH_QUEUE_SERIAL);
    self.trackingQueue = dispatch_queue_create("dev.manual7.tracking", DISPATCH_QUEUE_SERIAL);
    self.webcamQueue = dispatch_queue_create("dev.manual7.webcam.encode", DISPATCH_QUEUE_SERIAL);
    self.pairingQueue = dispatch_queue_create("dev.manual7.pairing.scan", DISPATCH_QUEUE_SERIAL);
    self.remoteQueue = dispatch_queue_create("dev.manual7.remote.lifecycle", DISPATCH_QUEUE_SERIAL);
    self.controllerID = NSUUID.UUID.UUIDString;
    self.sessionID = NSUUID.UUID.UUIDString;
    self.photoOnlyRequested = atomic_load(&M7PhotoOnlyPreferred);
    self.sessionEvents = [NSMutableArray new];
    self.pendingVideos = [NSMutableArray new];
    self.remoteEvents = [NSMutableArray new];
    self.openSSHStatus = @{ @"checking":@YES, @"package":@"openssh-server",
        @"checkedPorts":@[@22, @2222] };
    self.subjectTracker = [M7SubjectTracker new];
    self.trackingCenter = CGPointMake(.5, .5);
    self.remotePIN = [NSString stringWithFormat:@"%06u", arc4random_uniform(900000)+100000];
    self.webcamEncoder = [M7WebcamEncoder new];
    NSNumber *savedMount = [NSUserDefaults.standardUserDefaults objectForKey:M7CameraMountDefaultsKey];
    NSInteger mount = [savedMount isKindOfClass:NSNumber.class] ? savedMount.integerValue : M7CameraMountLandscape;
    self.cameraMount = mount >= M7CameraMountLandscape && mount <= M7CameraMountPortrait ?
        (M7CameraMount)mount : M7CameraMountLandscape;
    self.pairingManager = [M7PairingManager new];
    self.remoteBindAttempts = @[];
    self.remoteStartup = @{ @"state":@"pending", @"reason":@"viewDidLoad" };
    self.videoBackgroundTask = UIBackgroundTaskInvalid;
    self.session = [AVCaptureSession new]; M7MarkSessionOwned(self.session);
    self.peakingThreshold = .2;

    self.closeButton = [self button:@"Fechar" action:@selector(close)];
    self.shareButton = [self button:@"Exportar" action:@selector(share)];
    self.shareButton.enabled = YES;
    UILabel *title = [UILabel new]; title.text = @"MANUAL7";
    title.font = [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightSemibold];
    title.textAlignment = NSTextAlignmentCenter;
    UIStackView *top = [[UIStackView alloc] initWithArrangedSubviews:@[self.closeButton, title, self.shareButton]];
    top.distribution = UIStackViewDistributionEqualSpacing;
    top.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:top];

    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    scroll.alwaysBounceVertical = YES;
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2; stack.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:stack];
    self.previewView = [UIView new]; self.previewView.clipsToBounds = YES;
    self.previewView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.previewView];
    self.preview = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
    self.preview.videoGravity = AVLayerVideoGravityResizeAspect;
    [self.previewView.layer addSublayer:self.preview];
    self.peakingView = [UIImageView new]; self.peakingView.contentMode = UIViewContentModeScaleAspectFit;
    self.peakingView.userInteractionEnabled = NO;
    [self.previewView addSubview:self.peakingView];
    self.reframeGuideLayer = [CAShapeLayer layer];
    self.reframeGuideLayer.fillColor = UIColor.clearColor.CGColor;
    self.reframeGuideLayer.lineWidth = 1.5;
    self.reframeGuideLayer.lineDashPattern = @[@7, @5];
    [self.previewView.layer addSublayer:self.reframeGuideLayer];
    self.focusIndicator = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 72, 72)];
    self.focusIndicator.layer.borderColor = UIColor.systemYellowColor.CGColor;
    self.focusIndicator.layer.borderWidth = 1.5;
    self.focusIndicator.userInteractionEnabled = NO;
    self.focusIndicator.hidden = YES;
    [self.previewView addSubview:self.focusIndicator];
    self.previewView.accessibilityHint = @"Toque para focar e medir a exposição nesse ponto.";
    [self.previewView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
        action:@selector(previewTapped:)]];
    // Pinned below the preview so the measured values never scroll away.
    self.readout = [UILabel new]; self.readout.numberOfLines = 2;
    self.readout.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.readout.textAlignment = NSTextAlignmentCenter;
    self.readout.adjustsFontSizeToFitWidth = YES; self.readout.minimumScaleFactor = .8;
    self.readout.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.readout];
    self.status = [UILabel new]; self.status.numberOfLines = 3;
    self.status.font = [UIFont systemFontOfSize:12]; self.status.textColor = UIColor.systemYellowColor;
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    self.status.userInteractionEnabled = YES;
    self.status.accessibilityHint = @"Toque para mostrar endereços IP ocultos.";
    [self.status addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
        action:@selector(toggleReveal:)]];
    [self.view addSubview:self.status];
    [self message:@"Preparando câmera…"];

    self.captureMode = [[UISegmentedControl alloc] initWithItems:@[@"Foto", @"Vídeo"]];
    self.captureMode.selectedSegmentIndex = 0;
    [self.captureMode addTarget:self action:@selector(changeCaptureMode) forControlEvents:UIControlEventValueChanged];
    self.lens = [[UISegmentedControl alloc] initWithItems:@[@"1×", @"2×"]]; self.lens.selectedSegmentIndex = 0;
    [self.lens addTarget:self action:@selector(changeLens) forControlEvents:UIControlEventValueChanged];
    self.rawSwitch = [UISwitch new]; self.rawSwitch.on = YES;
    [self.rawSwitch addTarget:self action:@selector(updateSizeControl) forControlEvents:UIControlEventValueChanged];
    self.rawRow = [self row:@"DNG RAW" control:self.rawSwitch];
    self.sizeButton = [self button:@"Original" action:@selector(chooseJPEGSize)];
    self.sizeButton.accessibilityLabel = @"Tamanho da fotografia JPEG";
    self.sizeRow = [self row:@"Tamanho" control:self.sizeButton];
    self.videoFormat = [[UISegmentedControl alloc] initWithItems:@[@"16:9", @"9:16", @"Ambos"]];
    self.videoFormat.selectedSegmentIndex = 2;
    [self.videoFormat addTarget:self action:@selector(changeVideoFormat) forControlEvents:UIControlEventValueChanged];
    self.videoFormatRow = [self row:@"Reframe" control:self.videoFormat];
    self.videoFormatRow.hidden = YES;
    self.trackingSwitch = [UISwitch new];
    [self.trackingSwitch addTarget:self action:@selector(changeTracking) forControlEvents:UIControlEventValueChanged];
    self.trackingRow = [self row:@"Rastrear" control:self.trackingSwitch];
    self.trackingRow.hidden = YES;
    [stack addArrangedSubview:[self section:@"Captura"]];
    [stack addArrangedSubview:[self row:@"Modo" control:self.captureMode]];
    [stack addArrangedSubview:[self row:@"Lente" control:self.lens]];
    [stack addArrangedSubview:self.rawRow];
    [stack addArrangedSubview:self.sizeRow];
    [stack addArrangedSubview:self.videoFormatRow];
    [stack addArrangedSubview:self.trackingRow];

    // Rows that only apply to one mode are hidden by enableControls.
    self.exposureMode = [[UISegmentedControl alloc] initWithItems:@[@"AUTO", @"M", @"AE-L"]];
    self.exposureMode.selectedSegmentIndex = 0;
    [self.exposureMode addTarget:self action:@selector(changeExposureMode) forControlEvents:UIControlEventValueChanged];
    self.isoSlider = [self slider:@"ISO manual" action:@selector(changeManualExposure)];
    self.shutterSlider = [self slider:@"Obturador em terços de stop" action:@selector(changeManualExposure)];
    self.evStepper = [UIStepper new]; self.evStepper.stepValue = 1;
    self.evStepper.accessibilityLabel = @"Compensação EV em terços de stop";
    [self.evStepper addTarget:self action:@selector(changeEV) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self section:@"Exposição"]];
    [stack addArrangedSubview:[self row:@"Modo" control:self.exposureMode]];
    [stack addArrangedSubview:[self row:@"ISO" control:self.isoSlider]];
    [stack addArrangedSubview:[self row:@"Shutter" control:self.shutterSlider]];
    [stack addArrangedSubview:[self row:@"EV ±⅓" control:self.evStepper]];

    self.focusMode = [[UISegmentedControl alloc] initWithItems:@[@"AF", @"MF", @"AF-L"]];
    self.focusMode.selectedSegmentIndex = 0;
    [self.focusMode addTarget:self action:@selector(changeFocusMode) forControlEvents:UIControlEventValueChanged];
    self.focusSlider = [self slider:@"Posição do foco de perto a longe" action:@selector(changeManualFocus)];
    self.focusSlider.continuous = YES;
    [self.focusSlider addTarget:self action:@selector(changeManualFocus)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    self.peakingSwitch = [UISwitch new];
    [self.peakingSwitch addTarget:self action:@selector(changePeaking) forControlEvents:UIControlEventValueChanged];
    self.thresholdSlider = [self slider:@"Limiar do focus peaking" action:@selector(changePeaking)];
    self.thresholdSlider.minimumValue = .03; self.thresholdSlider.maximumValue = .6; self.thresholdSlider.value = .2;
    [stack addArrangedSubview:[self section:@"Foco"]];
    [stack addArrangedSubview:[self row:@"Modo" control:self.focusMode]];
    [stack addArrangedSubview:[self row:@"Perto/longe" control:self.focusSlider]];
    [stack addArrangedSubview:[self row:@"Peaking" control:self.peakingSwitch]];
    [stack addArrangedSubview:[self row:@"Limiar" control:self.thresholdSlider]];

    self.remoteLabel = [UILabel new];
    self.remoteLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.remoteLabel.adjustsFontSizeToFitWidth = YES;
    self.remoteLabel.minimumScaleFactor = .7;
    self.remoteLabel.accessibilityLabel = @"Controle remoto por SSH";
    self.remoteLabel.accessibilityHint = @"Toque para mostrar o PIN.";
    self.remoteLabel.userInteractionEnabled = YES;
    [self.remoteLabel addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
        action:@selector(toggleReveal:)]];
    [self setRemoteStatus:@"Bridge iniciando em segundo plano" color:UIColor.systemYellowColor showsPIN:YES];
    self.pairButton = [self button:@"Ler QR do PC" action:@selector(togglePairingScan)];
    self.pairButton.accessibilityLabel = @"Parear Manual7 com notebook Linux por QR Code";
    self.webcamSwitch = [UISwitch new];
    [self.webcamSwitch addTarget:self action:@selector(changeWebcam) forControlEvents:UIControlEventValueChanged];
    self.webcamFormat = [[UISegmentedControl alloc] initWithItems:@[@"16:9", @"9:16"]];
    self.webcamFormat.selectedSegmentIndex = 0;
    [self.webcamFormat addTarget:self action:@selector(changeWebcamFormat) forControlEvents:UIControlEventValueChanged];
    self.mountControl = [[UISegmentedControl alloc] initWithItems:@[@"Paisagem", @"Invertida", @"Retrato"]];
    self.mountControl.selectedSegmentIndex = self.cameraMount;
    self.mountControl.accessibilityLabel = @"Montagem do iPhone: paisagem com o botão Home à direita, invertida ou retrato";
    [self.mountControl addTarget:self action:@selector(changeCameraMount) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self section:@"Conexão com o PC"]];
    [stack addArrangedSubview:[self row:@"Remoto" control:self.remoteLabel]];
    [stack addArrangedSubview:[self row:@"Pareamento" control:self.pairButton]];
    [stack addArrangedSubview:[self row:@"Webcam" control:self.webcamSwitch]];
    [stack addArrangedSubview:[self row:@"Formato" control:self.webcamFormat]];
    [stack addArrangedSubview:[self row:@"Montagem" control:self.mountControl]];

    self.shutterButton = [self button:@"●  FOTOGRAFAR" action:@selector(shutterTapped)];
    self.shutterButton.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
    self.shutterButton.backgroundColor = UIColor.systemYellowColor;
    [self.shutterButton setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
    [self.shutterButton setTitleColor:UIColor.blackColor forState:UIControlStateDisabled];
    self.shutterButton.layer.cornerRadius = 27;
    self.shutterButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.shutterButton];
    [NSLayoutConstraint activateConstraints:@[
        [top.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:12],
        [top.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-12],
        [top.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [self.previewView.topAnchor constraintEqualToAnchor:top.bottomAnchor],
        [self.previewView.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.previewView.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.previewView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor multiplier:.40],
        [self.readout.topAnchor constraintEqualToAnchor:self.previewView.bottomAnchor constant:2],
        [self.readout.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.readout.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.readout.heightAnchor constraintEqualToConstant:32],
        [scroll.topAnchor constraintEqualToAnchor:self.readout.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-4],
        [self.status.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.status.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.status.bottomAnchor constraintEqualToAnchor:self.shutterButton.topAnchor constant:-4],
        [self.status.heightAnchor constraintEqualToConstant:44],
        [self.shutterButton.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.shutterButton.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.shutterButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-6],
        [self.shutterButton.heightAnchor constraintEqualToConstant:54],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    [self enableControls:NO];
    [self scheduleRemoteServerStart:@"viewDidLoad"];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:.3 repeats:YES block:^(__unused NSTimer *t) {
        [weakSelf refresh];
    }];
    self.timer.tolerance = .1;
    NSMutableArray *observers = [NSMutableArray new];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationWillResignActiveNotification,
          UIApplicationDidBecomeActiveNotification, AVCaptureSessionWasInterruptedNotification,
          AVCaptureSessionInterruptionEndedNotification, AVCaptureSessionRuntimeErrorNotification,
          NSProcessInfoThermalStateDidChangeNotification]) {
        id token = [nc addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { [weakSelf notification:note]; }];
        [observers addObject:token];
    }
    self.observers = observers;
    dispatch_async(self.sessionQueue, ^{
        self.storage = [[M7Storage alloc] initWithCandidates:M7Storage.defaultCandidates];
        self.photosInFlight = [NSMutableSet new];
        self.photosImported = [NSMutableSet new];
        self.photoResults = [NSMutableDictionary new];
        [self.storage prepare:nil];
        NSError *videoDirectoryError = nil;
        NSURL *videoDirectory = [self videoWorkingDirectoryWithError:&videoDirectoryError];
        NSArray<NSURL *> *videoFiles = videoDirectory ? [NSFileManager.defaultManager
            contentsOfDirectoryAtURL:videoDirectory includingPropertiesForKeys:@[NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles error:&videoDirectoryError] : @[];
        for (NSURL *url in videoFiles) {
            NSNumber *regular = nil; [url getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            NSString *extension = url.pathExtension.lowercaseString;
            if (!regular.boolValue || (![@"mp4" isEqual:extension] && ![@"mov" isEqual:extension])) continue;
            NSString *label = [url.lastPathComponent containsString:@"vertical9x16"] ? @"vertical9x16" :
                [url.lastPathComponent containsString:@"horizontal16x9"] ? @"horizontal16x9" : @"master4x3";
            [self.pendingVideos addObject:@{@"url":url, @"label":label}];
        }
        [self recordSessionEvent:@"temporaryVideoDiscovery" details:@{@"pending":@(self.pendingVideos.count),
            @"directory":videoDirectory.path ?: @"", @"error":M7ErrorDetails(videoDirectoryError)}];
        // Keep the previous attempt available until the next shutter press.
        for (NSURL *directory in self.storage.candidates) {
            NSURL *traceFile = [directory URLByAppendingPathComponent:@"ultima-captura.json"];
            NSData *data = [NSData dataWithContentsOfURL:traceFile];
            id trace = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
            if ([trace isKindOfClass:NSMutableDictionary.class] &&
                (!self.captureTrace || [trace[@"updatedAt"] doubleValue] > [self.captureTrace[@"updatedAt"] doubleValue])) self.captureTrace = trace;
        }
    });
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.startedSetup || self.closing) return;
    self.startedSetup = YES;
    dispatch_async(self.sessionQueue, ^{
        M7BeginCameraOwnership();
        NSError *error = nil;
        if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] != AVAuthorizationStatusAuthorized) {
            [self message:@"Acesso à câmera indisponível. Autorize a Câmera e reabra o M7."]; return;
        }
        self.photoOutput = [AVCapturePhotoOutput new];
        self.photoOutput.maxPhotoQualityPrioritization = AVCapturePhotoQualityPrioritizationSpeed;
        self.photoOutput.highResolutionCaptureEnabled = YES;
        self.videoOutput = [AVCaptureVideoDataOutput new];
        self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
        self.videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
        self.audioOutput = [AVCaptureAudioDataOutput new];
        [self.audioOutput setSampleBufferDelegate:self queue:self.videoQueue];
        [self.session beginConfiguration];
        self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        BOOL outputsOK = [self.session canAddOutput:self.photoOutput];
        if (outputsOK) [self.session addOutput:self.photoOutput];
        BOOL videoOK = !self.photoOnlyRequested && [self.session canAddOutput:self.videoOutput];
        if (videoOK) [self.session addOutput:self.videoOutput];
        [self.session commitConfiguration];
        if (!outputsOK || ![self selectDevice:AVCaptureDeviceTypeBuiltInWideAngleCamera error:&error]) {
            [self message:error.localizedDescription ?: @"Não foi possível configurar a captura."]; return;
        }
        self.configured = YES;
        [self.session startRunning];
        [self recordSessionEvent:@"setup" details:[self sessionDiagnostic]];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.peakingSwitch.enabled = videoOK;
            [self message:videoOK ? @"Deslize para acessar os controles. DNG usa o sensor da lente selecionada." : @"Preview sem saída para peaking nesta configuração."];
        });
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.preview.frame = self.previewView.bounds;
    self.peakingView.frame = self.previewView.bounds;
    if (self.preview.connection.isVideoOrientationSupported)
        self.preview.connection.videoOrientation = AVCaptureVideoOrientationPortrait;
    [self updateReframeGuide];
}

- (void)previewTapped:(UITapGestureRecognizer *)tap {
    CGPoint location = [tap locationInView:self.previewView];
    CGRect video = [self.preview rectForMetadataOutputRectOfInterest:CGRectMake(0, 0, 1, 1)];
    if (!CGRectContainsPoint(video, location)) return;
    CGPoint point = [self.preview captureDevicePointOfInterestForPoint:location];
    UIView *box = self.focusIndicator;
    [box.layer removeAllAnimations];
    box.center = location; box.alpha = 1; box.hidden = NO;
    box.transform = CGAffineTransformMakeScale(1.35, 1.35);
    [UIView animateWithDuration:.2 animations:^{ box.transform = CGAffineTransformIdentity; }];
    [UIView animateWithDuration:.3 delay:1 options:UIViewAnimationOptionBeginFromCurrentState
        animations:^{ box.alpha = 0; } completion:nil];
    dispatch_async(self.sessionQueue, ^{ [self focusAtDevicePoint:point origin:@"tap"]; });
}

// sessionQueue only. Continuous AF/AE adopt the point; manual or locked modes
// keep their values, and the status line says which ones moved.
- (void)focusAtDevicePoint:(CGPoint)point origin:(NSString *)origin {
    if (!self.configured || !self.controls || self.captureBusy || self.closing) {
        [self message:@"A câmera não está pronta para focar."]; return;
    }
    NSError *error = nil;
    NSDictionary *applied = [self.controls setPointOfInterest:point error:&error];
    [self recordControlChange:@"pointOfInterest" details:@{ @"origin":origin ?: @"", @"x":@(point.x),
        @"y":@(point.y), @"applied":applied ?: @{}, @"error":M7ErrorDetails(error) }];
    if (!applied) { [self message:error.localizedDescription]; return; }
    BOOL focus = [applied[@"focus"] boolValue], exposure = [applied[@"exposure"] boolValue];
    [self message:focus && exposure ? @"Foco e exposição ajustados no ponto tocado." :
        focus ? @"Foco no ponto tocado; exposição manual/bloqueada mantida." :
        @"Exposição no ponto tocado; foco manual/bloqueado mantido."];
}

// framePoint is top-left normalized in the published webcam frame, or in the
// whole camera frame while the webcam is off.
- (void)focusAtFramePoint:(CGPoint)framePoint {
    BOOL webcam = self.webcamEnabled, vertical = self.webcamVertical;
    CGPoint center = self.trackingEnabled ? self.trackingCenter : CGPointMake(.5, .5);
    M7CameraMount mount = self.cameraMount;
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice *device = self.input.device;
        CMVideoDimensions native = device.activeFormat.formatDescription ?
            CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription) : (CMVideoDimensions){0, 0};
        // The format is landscape; portrait buffers swap its sides.
        CGFloat longSide = MAX(native.width, native.height), shortSide = MIN(native.width, native.height);
        BOOL landscape = mount != M7CameraMountPortrait;
        CGSize source = landscape ? CGSizeMake(longSide, shortSide) : CGSizeMake(shortSide, longSide);
        // Only the aspect ratio of the target matters for the crop.
        CGSize target = !webcam ? source : M7WebcamOutputSize(M7WebcamCodecMJPEG, vertical, landscape);
        [self focusAtDevicePoint:M7WebcamDevicePointForMount(mount, source, target, center, framePoint)
            origin:@"remote"];
    });
}

// sessionQueue only. In Photo mode the data output feeds only peaking and the
// QR reader; with both off its connection is disabled so the camera stops
// delivering ~30 unused frames per second to videoQueue.
- (void)updateVideoOutputDemand {
    AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    BOOL needed = self.videoModeActive || self.peakingEnabled || self.pairingScanning;
    if (connection && connection.enabled != needed) connection.enabled = needed;
}

// Maps a top-left normalized point of the video buffer into `frame`, the
// portrait preview of the sensor: the device space (landscape, Home button on
// the right) appears rotated 90° clockwise there.
- (CGPoint)previewPointForBufferPoint:(CGPoint)point inFrame:(CGRect)frame {
    CGPoint device = M7CameraMountDevicePoint(self.cameraMount, point);
    return CGPointMake(CGRectGetMinX(frame) + (1.0 - device.y) * CGRectGetWidth(frame),
        CGRectGetMinY(frame) + device.x * CGRectGetHeight(frame));
}

- (CGRect)previewRectForBufferRect:(CGRect)rect inFrame:(CGRect)frame {
    CGPoint a = [self previewPointForBufferPoint:rect.origin inFrame:frame];
    CGPoint b = [self previewPointForBufferPoint:CGPointMake(CGRectGetMaxX(rect), CGRectGetMaxY(rect))
        inFrame:frame];
    return CGRectMake(MIN(a.x, b.x), MIN(a.y, b.y), fabs(a.x - b.x), fabs(a.y - b.y));
}

- (void)updateReframeGuide {
    if (self.captureMode.selectedSegmentIndex != 1) {
        self.reframeGuideLayer.path = nil; return;
    }
    CGRect bounds = self.previewView.bounds;
    CGFloat width = CGRectGetWidth(bounds), height = CGRectGetHeight(bounds);
    if (width <= 0 || height <= 0) return;
    // The preview always shows the 4:3 sensor in portrait. The crops and the
    // Vision center live in the buffer's normalized, top-left space, which the
    // mount may rotate relative to the preview.
    CGFloat masterWidth = MIN(width, height * 3.0/4.0);
    CGFloat masterHeight = masterWidth * 4.0/3.0;
    if (masterHeight > height) { masterHeight = height; masterWidth = height * 3.0/4.0; }
    CGRect master = CGRectMake((width-masterWidth)/2.0, (height-masterHeight)/2.0,
        masterWidth, masterHeight);
    CGSize buffer = self.cameraMount == M7CameraMountPortrait ? CGSizeMake(3, 4) : CGSizeMake(4, 3);
    CGPoint center = self.trackingSwitch.on ? self.trackingCenter : CGPointMake(.5, .5);
    CGRect (^bufferCrop)(CGSize) = ^CGRect(CGSize target) {
        CGRect crop = M7WebcamCropRect(buffer, target, center);  // Core Image: bottom-left origin.
        return CGRectMake(CGRectGetMinX(crop) / buffer.width,
            (buffer.height - CGRectGetMaxY(crop)) / buffer.height,
            CGRectGetWidth(crop) / buffer.width, CGRectGetHeight(crop) / buffer.height);
    };
    UIBezierPath *path = [UIBezierPath bezierPath];
    NSInteger mode = self.videoFormat.selectedSegmentIndex;
    if (mode == 0 || mode == 2)
        [path appendPath:[UIBezierPath bezierPathWithRect:[self previewRectForBufferRect:
            bufferCrop(CGSizeMake(16, 9)) inFrame:master]]];
    if (mode == 1 || mode == 2)
        [path appendPath:[UIBezierPath bezierPathWithRect:[self previewRectForBufferRect:
            bufferCrop(CGSizeMake(9, 16)) inFrame:master]]];
    if (self.trackingSwitch.on) {
        CGPoint marker = [self previewPointForBufferPoint:center inFrame:master];
        [path appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectMake(marker.x-8, marker.y-8, 16, 16)]];
    }
    self.reframeGuideLayer.frame = bounds;
    self.reframeGuideLayer.strokeColor = self.trackingSwitch.on && self.trackingDetected ?
        UIColor.systemGreenColor.CGColor : UIColor.systemYellowColor.CGColor;
    self.reframeGuideLayer.path = path.CGPath;
}

- (void)message:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusText = text;
        self.statusRevealed = NO;
        [self renderStatus];
    });
}

// Main thread only.
- (void)renderStatus {
    self.status.text = self.statusRevealed ? (self.statusText ?: @"") : M7RedactIPv4(self.statusText);
}

// Main thread only. The PIN is appended masked unless the user revealed it.
- (void)setRemoteStatus:(NSString *)text color:(UIColor *)color showsPIN:(BOOL)showsPIN {
    self.remoteStatusText = text;
    self.remoteShowsPIN = showsPIN;
    self.remoteLabel.textColor = color;
    [self renderRemoteStatus];
}

- (void)renderRemoteStatus {
    NSString *text = self.remoteStatusText ?: @"";
    if (self.remoteShowsPIN)
        text = [text stringByAppendingFormat:@" · PIN %@", self.pinRevealed ? self.remotePIN : M7PINMask];
    self.remoteLabel.text = text;
}

- (void)toggleReveal:(UITapGestureRecognizer *)tap {
    BOOL pin = tap.view == self.remoteLabel;
    BOOL revealed;
    if (pin) {
        if (!self.remoteShowsPIN) return;
        revealed = self.pinRevealed = !self.pinRevealed;
        [self renderRemoteStatus];
    } else {
        if ([M7RedactIPv4(self.statusText) isEqualToString:self.statusText ?: @""]) return;
        revealed = self.statusRevealed = !self.statusRevealed;
        [self renderStatus];
    }
    [[UISelectionFeedbackGenerator new] selectionChanged];
    if (!revealed) return;
    NSUInteger generation = ++self.revealGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(M7RevealSeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
        typeof(self) owner = weakSelf;
        if (!owner || generation != owner.revealGeneration) return;
        owner.pinRevealed = NO; owner.statusRevealed = NO;
        [owner renderRemoteStatus]; [owner renderStatus];
    });
}

- (void)recordRemoteEvent:(NSString *)stage requestID:(NSString *)requestID
    details:(NSDictionary *)details {
    dispatch_async(self.sessionQueue, ^{
        NSDictionary *event = @{ @"stage":stage ?: @"", @"time":@(NSDate.date.timeIntervalSince1970),
            @"requestID":requestID ?: @"", @"details":M7JSONSnapshot(details ?: @{}) };
        [self.remoteEvents addObject:event];
        if (self.remoteEvents.count > 256) [self.remoteEvents removeObjectAtIndex:0];
        [self recordSessionEvent:@"remoteControl" details:event];
        BOOL commandEvent = [details[@"body"][@"command"] isKindOfClass:NSString.class] ||
            [details[@"command"] isKindOfClass:NSString.class];
        if ((self.videoRecording || self.videoProcessing) && commandEvent)
            [self recordVideoStage:@"remoteControl" details:event];
    });
}

- (void)scheduleRemoteServerStart:(NSString *)reason {
    if (self.closing) return;
    NSUInteger generation = ++self.remoteGeneration;
    self.remoteStarting = YES;
    NSTimeInterval requestedAt = NSDate.date.timeIntervalSince1970;
    self.remoteStartup = @{ @"state":@"starting", @"reason":reason ?: @"",
        @"generation":@(generation), @"requestedAt":@(requestedAt),
        @"runsOffMainThread":@YES, @"connectTimeoutMilliseconds":@250 };
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closing || generation != self.remoteGeneration) return;
        [self setRemoteStatus:@"Bridge iniciando em segundo plano" color:UIColor.systemYellowColor
            showsPIN:YES];
    });
    dispatch_async(self.remoteQueue, ^{
        if (self.closing || generation != self.remoteGeneration) return;
        [self startRemoteServerForReason:reason requestedAt:requestedAt generation:generation];
    });
}

- (void)startRemoteServerForReason:(NSString *)reason requestedAt:(NSTimeInterval)requestedAt
    generation:(NSUInteger)generation {
    __weak typeof(self) weakSelf = self;
    M7RemoteRequestHandler handler = ^(NSDictionary *request, M7RemoteResponse response) {
        typeof(self) owner = weakSelf;
        if (!owner) { response(503, @{ @"ok":@NO, @"error":@"O painel M7 foi encerrado." }); return; }
        [owner handleRemoteRequest:request response:response];
    };
    NSMutableArray<NSDictionary *> *attempts = [NSMutableArray new];
    NSError *error = nil;
    BOOL started = self.remoteServer && [self.remoteServer start:&error];
    if (self.remoteServer) [attempts addObject:@{ @"transport":@"launchdBridge",
        @"path":self.remoteSocketPath ?: @"", @"reused":@YES,
        @"success":@(started), @"error":M7ErrorDetails(error) }];
    if (!started) {
        [self.remoteServer stop];
        self.remoteServer = nil;
        self.webcamServer = nil;
        self.remoteSocketPath = nil;
        self.webcamSocketPath = nil;
        NSString *publicAPIPath = @"/var/tmp/Manual7-api.sock";
        NSString *publicWebcamPath = @"/var/tmp/Manual7-webcam.sock";
        M7RemoteServer *bridge = [[M7RemoteServer alloc] initWithBridgePort:27837
            publicUnixSocketPath:publicAPIPath magic:@"M7-CAMERA-API-1\n"
            pin:self.remotePIN handler:handler];
        NSError *bridgeError = nil;
        BOOL bridgeStarted = [bridge start:&bridgeError];
        error = bridgeError;
        [attempts addObject:@{ @"transport":@"launchdBridge", @"path":publicAPIPath,
            @"workerPort":@27837, @"success":@(bridgeStarted),
            @"error":M7ErrorDetails(bridgeError) }];
        if (bridgeStarted) {
            self.remoteServer = bridge;
            self.remoteSocketPath = publicAPIPath;
            self.webcamSocketPath = publicWebcamPath;
            self.webcamServer = [[M7WebcamServer alloc] initWithBridgePort:27838
                publicUnixSocketPath:publicWebcamPath magic:@"M7-CAMERA-WEBCAM-1\n"
                pin:self.remotePIN];
            error = nil;
            started = YES;
        }
    }
    NSTimeInterval completedAt = NSDate.date.timeIntervalSince1970;
    NSTimeInterval duration = MAX(0, completedAt - requestedAt);
    self.remoteBindAttempts = attempts;
    self.remoteStarting = NO;
    self.remoteStartup = @{ @"state":started ? @"ready" : @"failed",
        @"reason":reason ?: @"", @"generation":@(generation),
        @"requestedAt":@(requestedAt), @"completedAt":@(completedAt),
        @"durationMilliseconds":@(duration * 1000), @"runsOffMainThread":@YES,
        @"connectTimeoutMilliseconds":@250, @"fallbackSocketsAttempted":@NO,
        @"error":M7ErrorDetails(error) };
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.closing || generation != self.remoteGeneration) return;
        [self setRemoteStatus:started ? @"OpenSSH… · API bridge" : @"API indisponível · câmera disponível"
            color:started ? UIColor.systemYellowColor : UIColor.systemRedColor showsPIN:started];
    });
    [self recordRemoteEvent:started ? @"serverStarted" : @"serverStartFailed" requestID:@""
        details:@{ @"server":self.remoteServer.snapshot ?: @{}, @"error":M7ErrorDetails(error),
            @"bindAttempts":attempts, @"startup":self.remoteStartup ?: @{} }];
    NSDictionary *status = M7OpenSSHStatus();
    self.openSSHStatus = status;
    [self recordRemoteEvent:@"openSSHChecked" requestID:@"" details:status];
    dispatch_async(dispatch_get_main_queue(), ^{
            if (self.closing || generation != self.remoteGeneration ||
                UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
            if (!started && [status[@"serviceReachable"] boolValue]) {
                [self setRemoteStatus:[NSString stringWithFormat:@"SSH %@ · API indisponível",
                    status[@"preferredPort"]] color:UIColor.systemRedColor showsPIN:NO];
            } else if (!started) {
                [self setRemoteStatus:@"API indisponível · ver diagnóstico" color:UIColor.systemRedColor
                    showsPIN:NO];
            } else if ([status[@"serviceReachable"] boolValue]) {
                [self setRemoteStatus:[NSString stringWithFormat:@"SSH %@ · API bridge",
                    status[@"preferredPort"]] color:UIColor.systemGreenColor showsPIN:YES];
            } else if ([status[@"installed"] boolValue]) {
                [self setRemoteStatus:@"OpenSSH iniciando · API bridge" color:UIColor.systemYellowColor
                    showsPIN:YES];
            } else {
                [self setRemoteStatus:@"OpenSSH ausente · reinstale M7" color:UIColor.systemRedColor
                    showsPIN:NO];
            }
    });
}

- (void)stopRemoteServerReason:(NSString *)reason {
    NSUInteger generation = ++self.remoteGeneration;
    self.remoteStarting = NO;
    dispatch_async(self.remoteQueue, ^{
        NSDictionary *before = self.remoteServer.snapshot ?: @{};
        [self.remoteServer stop];
        self.remoteStartup = @{ @"state":@"stopped", @"reason":reason ?: @"",
            @"generation":@(generation), @"stoppedAt":@(NSDate.date.timeIntervalSince1970) };
        [self recordRemoteEvent:@"serverStopped" requestID:@""
            details:@{ @"reason":reason ?: @"", @"before":before }];
    });
}

- (NSDictionary *)remoteUIState {
    NSString *captureName = self.captureMode.selectedSegmentIndex == 1 ? @"video" : @"photo";
    NSString *lensName = self.lens.selectedSegmentIndex == 1 ? @"tele" : @"wide";
    NSArray *exposureNames = @[@"auto", @"manual", @"lock"];
    NSArray *focusNames = @[@"auto", @"manual", @"lock"];
    NSArray *videoNames = @[@"horizontal", @"vertical", @"both"];
    NSArray *webcamNames = @[@"horizontal", @"vertical"];
    NSString *mountName = M7CameraMountName(self.cameraMount);
    NSInteger exposureIndex = MIN((NSInteger)2, MAX((NSInteger)0, self.exposureMode.selectedSegmentIndex));
    NSInteger focusIndex = MIN((NSInteger)2, MAX((NSInteger)0, self.focusMode.selectedSegmentIndex));
    NSInteger videoIndex = MIN((NSInteger)2, MAX((NSInteger)0, self.videoFormat.selectedSegmentIndex));
    NSInteger webcamIndex = MIN((NSInteger)1, MAX((NSInteger)0, self.webcamFormat.selectedSegmentIndex));
    return @{ @"captureMode":captureName, @"lens":lensName,
        @"exposureMode":exposureNames[exposureIndex], @"focusMode":focusNames[focusIndex],
        @"evThirds":@((NSInteger)self.evStepper.value), @"focusPosition":@(self.focusSlider.value),
        @"raw":@(self.rawSwitch.on), @"jpegLongEdge":@(self.jpegLongEdge),
        @"videoFormat":videoNames[videoIndex], @"tracking":@(self.trackingSwitch.on),
        @"webcam":@(self.webcamSwitch.on), @"webcamFormat":webcamNames[webcamIndex],
        @"cameraMount":mountName,
        @"peaking":@(self.peakingSwitch.on), @"peakingThreshold":@(self.thresholdSlider.value),
        @"videoRecording":@(self.videoRecording), @"videoProcessing":@(self.videoProcessing),
        @"captureBusy":@(self.captureBusy), @"rawCaptureWaiting":@(self.rawCaptureWaiting),
        @"configured":@(self.configured),
        @"available":@{ @"captureMode":@(self.captureMode.enabled), @"lens":@(self.lens.enabled),
            @"exposure":@(self.exposureMode.enabled), @"iso":@(self.isoSlider.enabled),
            @"shutter":@(self.shutterSlider.enabled), @"focus":@(self.focusMode.enabled),
            @"focusPosition":@(self.focusSlider.enabled), @"ev":@(self.evStepper.enabled),
            @"raw":@(self.rawSwitch.enabled), @"videoFormat":@(self.videoFormat.enabled),
            @"tracking":@(self.trackingSwitch.enabled), @"peaking":@(self.peakingSwitch.enabled),
            @"webcam":@(self.webcamSwitch.enabled), @"webcamFormat":@(self.webcamFormat.enabled),
            @"cameraMount":@(self.mountControl.enabled),
            @"shutterButton":@(self.shutterButton.enabled), @"focusPoint":@(self.captureAvailable) } };
}

- (void)remoteStateWithCompletion:(void (^)(NSDictionary *state))completion {
    NSDictionary *ui = [self remoteUIState];
    dispatch_async(self.sessionQueue, ^{
        NSMutableDictionary *state = [ui mutableCopy];
        AVCaptureDevice *device = self.input.device;
        state[@"actual"] = device ? @{ @"ISO":@(device.ISO),
            @"shutterSeconds":@(CMTimeGetSeconds(device.exposureDuration)),
            @"exposureBias":@(device.exposureTargetBias), @"meterEV":@(device.exposureTargetOffset),
            @"focusPosition":@(device.lensPosition), @"aperture":@(device.lensAperture) } : @{};
        state[@"limits"] = self.limits ?: @{};
        state[@"session"] = [self sessionDiagnostic];
        state[@"remoteServer"] = self.remoteServer.snapshot ?: @{};
        state[@"webcam"] = [self webcamSnapshot];
        // Lets the Studio estimate the clock offset for X-Timestamp latency.
        state[@"now"] = @(NSDate.date.timeIntervalSince1970);
        state[@"pairing"] = [self.pairingManager snapshot];
        state[@"openSSH"] = self.openSSHStatus ?: @{};
        completion(M7JSONSnapshot(state));
    });
}

- (void)handleRemoteRequest:(NSDictionary *)request response:(M7RemoteResponse)response {
    NSString *requestID = request[@"requestID"] ?: @"";
    NSString *method = request[@"method"] ?: @"";
    NSString *path = request[@"path"] ?: @"";
    NSDictionary *body = request[@"body"] ?: @{};
    // Manual7 Studio polls /v1/state about once per second. Logging every poll
    // cost two JSON round trips on the session queue and flushed the 32-entry
    // session log within seconds, so only failed polls are recorded.
    BOOL statePoll = [method isEqual:@"GET"] && [path isEqual:@"/v1/state"];
    if (!statePoll) [self recordRemoteEvent:@"request" requestID:requestID
        details:@{ @"method":method, @"path":path, @"body":body }];
    void (^finish)(NSInteger, NSDictionary *) = ^(NSInteger statusCode, NSDictionary *result) {
        NSMutableDictionary *payload = [result mutableCopy] ?: [NSMutableDictionary new];
        payload[@"requestID"] = requestID;
        if (statePoll && statusCode < 400) { response(statusCode, payload); return; }
        NSMutableDictionary *logResult = [@{ @"statusCode":@(statusCode),
            @"ok":payload[@"ok"] ?: @NO } mutableCopy];
        for (NSString *key in @[@"accepted", @"command", @"error"])
            if (payload[key]) logResult[key] = payload[key];
        [self recordRemoteEvent:@"response" requestID:requestID
            details:logResult];
        response(statusCode, payload);
    };
    if ([method isEqual:@"GET"] && [path isEqual:@"/v1/state"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self remoteStateWithCompletion:^(NSDictionary *state) {
                finish(200, @{ @"ok":@YES, @"version":@"0.7.7", @"state":state });
            }];
        });
        return;
    }
    if ([method isEqual:@"GET"] && [path isEqual:@"/v1/diagnostic"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *visibleStatus = self.status.text ?: @"";
            dispatch_async(self.sessionQueue, ^{
                finish(200, @{ @"ok":@YES,
                    @"report":[self diagnosticSnapshot:@"remote" status:visibleStatus] });
            });
        });
        return;
    }
    if ([method isEqual:@"POST"] && [path isEqual:@"/v1/command"]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self executeRemoteCommand:body requestID:requestID completion:finish];
        });
        return;
    }
    finish(404, @{ @"ok":@NO, @"error":@"Rota remota inexistente." });
}

- (NSDictionary *)applyRemoteControl:(NSString *)control value:(id)value error:(NSString **)error {
    NSString *text = [value isKindOfClass:NSString.class] ? [value lowercaseString] : @"";
    NSNumber *number = [value isKindOfClass:NSNumber.class] ? value : nil;
    if ([control isEqual:@"captureMode"]) {
        if (self.webcamRequested || self.webcamEnabled) {
            if (error) *error = @"Pare a webcam antes de trocar entre Foto e Vídeo.";
            return nil;
        }
        if (!self.captureMode.enabled) { if (error) *error = @"A troca Foto/Vídeo está bloqueada."; return nil; }
        NSInteger index = [text isEqual:@"photo"] ? 0 : [text isEqual:@"video"] ? 1 : -1;
        if (index < 0) { if (error) *error = @"captureMode aceita photo ou video."; return nil; }
        BOOL changed = self.captureMode.selectedSegmentIndex != index;
        self.captureMode.selectedSegmentIndex = index; if (changed) [self changeCaptureMode];
        return @{ @"control":control, @"value":text, @"changed":@(changed) };
    }
    if ([control isEqual:@"lens"]) {
        if (!self.lens.enabled) { if (error) *error = @"A lente está bloqueada durante a operação atual."; return nil; }
        NSInteger index = [text isEqual:@"wide"] ? 0 : [text isEqual:@"tele"] ? 1 : -1;
        if (index < 0) { if (error) *error = @"lens aceita wide ou tele."; return nil; }
        BOOL changed = self.lens.selectedSegmentIndex != index;
        self.lens.selectedSegmentIndex = index; if (changed) [self changeLens];
        return @{ @"control":control, @"value":text, @"changed":@(changed) };
    }
    if ([control isEqual:@"exposureMode"]) {
        if (!self.exposureMode.enabled) { if (error) *error = @"O controle de exposição está indisponível."; return nil; }
        NSInteger index = [text isEqual:@"auto"] ? 0 : [text isEqual:@"manual"] ? 1 : [text isEqual:@"lock"] ? 2 : -1;
        if (index < 0) { if (error) *error = @"exposureMode aceita auto, manual ou lock."; return nil; }
        BOOL changed = self.exposureMode.selectedSegmentIndex != index;
        self.exposureMode.selectedSegmentIndex = index; if (changed) [self changeExposureMode];
        return @{ @"control":control, @"value":text, @"changed":@(changed) };
    }
    if ([control isEqual:@"iso"]) {
        if (!number || !self.isoSlider.enabled) { if (error) *error = @"ISO requer exposição manual pronta."; return nil; }
        double iso = number.doubleValue, minimum = [self.limits[@"minISO"] doubleValue];
        double maximum = [self.limits[@"maxISO"] doubleValue];
        if (!isfinite(iso) || iso < minimum || iso > maximum || minimum <= 0 || maximum <= minimum) {
            if (error) *error = @"ISO fora dos limites informados em state.limits."; return nil;
        }
        self.isoSlider.value = (log(iso)-log(minimum))/(log(maximum)-log(minimum));
        [self changeManualExposure];
        return @{ @"control":control, @"value":@(iso), @"async":@YES };
    }
    if ([control isEqual:@"shutterSeconds"]) {
        if (!number || !self.shutterSlider.enabled) { if (error) *error = @"Shutter requer exposição manual pronta."; return nil; }
        double seconds = number.doubleValue;
        if (!isfinite(seconds) || seconds < [self.limits[@"minSeconds"] doubleValue] ||
            seconds > [self.limits[@"maxSeconds"] doubleValue]) {
            if (error) *error = @"shutterSeconds fora dos limites informados em state.limits."; return nil;
        }
        int index = 0;
        if (!m7_shutter_nearest(seconds, [self.limits[@"minSeconds"] doubleValue],
            [self.limits[@"maxSeconds"] doubleValue], &index)) {
            if (error) *error = @"Não foi possível mapear o shutter na grade de 1/3 stop."; return nil;
        }
        self.shutterSlider.value = index; [self changeManualExposure];
        return @{ @"control":control, @"requested":@(seconds),
            @"appliedGridSeconds":@(m7_shutter_seconds(index)), @"shutterIndex":@(index), @"async":@YES };
    }
    if ([control isEqual:@"evThirds"]) {
        if (!number || !self.evStepper.enabled) { if (error) *error = @"EV requer exposição automática desbloqueada."; return nil; }
        double raw = number.doubleValue; NSInteger thirds = (NSInteger)llround(raw);
        if (!isfinite(raw) || fabs(raw-thirds) > .0001 || thirds < self.evStepper.minimumValue || thirds > self.evStepper.maximumValue) {
            if (error) *error = @"evThirds deve ser inteiro e ficar dentro dos limites da câmera."; return nil;
        }
        self.evStepper.value = thirds; [self changeEV];
        return @{ @"control":control, @"value":@(thirds), @"ev":@(thirds/3.0), @"async":@YES };
    }
    if ([control isEqual:@"focusMode"]) {
        if (!self.focusMode.enabled) { if (error) *error = @"O modo de foco está indisponível."; return nil; }
        NSInteger index = [text isEqual:@"auto"] ? 0 : [text isEqual:@"manual"] ? 1 : [text isEqual:@"lock"] ? 2 : -1;
        if (index < 0) { if (error) *error = @"focusMode aceita auto, manual ou lock."; return nil; }
        BOOL changed = self.focusMode.selectedSegmentIndex != index;
        self.focusMode.selectedSegmentIndex = index; if (changed) [self changeFocusMode];
        return @{ @"control":control, @"value":text, @"changed":@(changed) };
    }
    if ([control isEqual:@"focusPosition"]) {
        if (!number || !self.focusSlider.enabled) { if (error) *error = @"focusPosition requer foco manual pronto."; return nil; }
        double position = number.doubleValue;
        if (!isfinite(position) || position < 0 || position > 1) {
            if (error) *error = @"focusPosition deve ficar entre 0 e 1."; return nil;
        }
        self.focusSlider.value = position; [self changeManualFocus];
        return @{ @"control":control, @"value":@(position), @"async":@YES };
    }
    if ([control isEqual:@"focusPoint"]) {
        NSDictionary *point = [value isKindOfClass:NSDictionary.class] ? value : nil;
        NSNumber *x = [point[@"x"] isKindOfClass:NSNumber.class] ? point[@"x"] : nil;
        NSNumber *y = [point[@"y"] isKindOfClass:NSNumber.class] ? point[@"y"] : nil;
        if (!x || !y || !isfinite(x.doubleValue) || !isfinite(y.doubleValue) || x.doubleValue < 0 ||
            x.doubleValue > 1 || y.doubleValue < 0 || y.doubleValue > 1) {
            if (error) *error = @"focusPoint requer {\"x\": 0…1, \"y\": 0…1}."; return nil;
        }
        if (!self.captureAvailable) { if (error) *error = @"A câmera não está pronta para focar."; return nil; }
        [self focusAtFramePoint:CGPointMake(x.doubleValue, y.doubleValue)];
        return @{ @"control":control, @"value":@{ @"x":x, @"y":y },
            @"frame":self.webcamEnabled ? @"webcam" : @"camera", @"async":@YES };
    }
    if ([control isEqual:@"raw"]) {
        if (!number || self.videoModeActive || !self.captureAvailable || (number.boolValue && !self.rawSwitch.enabled)) {
            if (error) *error = @"RAW está indisponível no modo ou lente atual."; return nil;
        }
        self.rawSwitch.on = number.boolValue; [self updateSizeControl];
        return @{ @"control":control, @"value":@(number.boolValue) };
    }
    if ([control isEqual:@"jpegLongEdge"]) {
        NSArray *allowed = @[@0, @3264, @2560, @2048, @1600, @1280];
        if (!number || self.videoModeActive || self.rawSwitch.on || !self.captureAvailable ||
            ![allowed containsObject:@(number.unsignedIntegerValue)]) {
            if (error) *error = @"jpegLongEdge aceita 0, 3264, 2560, 2048, 1600 ou 1280 com RAW desligado."; return nil;
        }
        NSUInteger edge = number.unsignedIntegerValue;
        NSUInteger native = MAX([self.limits[@"nativeWidth"] unsignedIntegerValue],
            [self.limits[@"nativeHeight"] unsignedIntegerValue]);
        if (edge && edge >= native) { if (error) *error = @"O tamanho JPEG solicitado não é menor que o sensor."; return nil; }
        self.jpegLongEdge = edge; [self updateSizeControl];
        return @{ @"control":control, @"value":@(edge) };
    }
    if ([control isEqual:@"videoFormat"]) {
        if (!self.videoFormat.enabled) { if (error) *error = @"Reframe está indisponível fora do modo Vídeo pronto."; return nil; }
        NSInteger index = [text isEqual:@"horizontal"] ? 0 : [text isEqual:@"vertical"] ? 1 : [text isEqual:@"both"] ? 2 : -1;
        if (index < 0) { if (error) *error = @"videoFormat aceita horizontal, vertical ou both."; return nil; }
        self.videoFormat.selectedSegmentIndex = index; [self changeVideoFormat];
        return @{ @"control":control, @"value":text };
    }
    if ([control isEqual:@"webcamFormat"]) {
        if (self.webcamRequested || self.webcamEnabled) {
            if (error) *error = @"Pare a webcam antes de alterar webcamFormat.";
            return nil;
        }
        NSInteger index = [text isEqual:@"horizontal"] ? 0 : [text isEqual:@"vertical"] ? 1 : -1;
        if (index < 0) { if (error) *error = @"webcamFormat aceita horizontal ou vertical."; return nil; }
        BOOL changed = self.webcamFormat.selectedSegmentIndex != index;
        self.webcamFormat.selectedSegmentIndex = index;
        if (changed) [self changeWebcamFormat];
        return @{ @"control":control, @"value":text, @"changed":@(changed) };
    }
    if ([control isEqual:@"cameraMount"]) {
        if (self.webcamRequested || self.webcamEnabled || self.videoRecording || self.videoProcessing) {
            if (error) *error = @"Pare a webcam e a gravação antes de alterar cameraMount.";
            return nil;
        }
        NSInteger index = [text isEqual:@"landscape"] ? M7CameraMountLandscape :
            [text isEqual:@"landscapeInverted"] ? M7CameraMountLandscapeInverted :
            [text isEqual:@"portrait"] ? M7CameraMountPortrait : -1;
        if (index < 0) {
            if (error) *error = @"cameraMount aceita landscape, landscapeInverted ou portrait.";
            return nil;
        }
        BOOL changed = self.mountControl.selectedSegmentIndex != index;
        self.mountControl.selectedSegmentIndex = index;
        if (changed) [self changeCameraMount];
        return @{ @"control":control, @"value":text, @"changed":@(changed) };
    }
    if ([control isEqual:@"tracking"]) {
        if (!number || !self.trackingSwitch.enabled) { if (error) *error = @"Tracking está indisponível agora."; return nil; }
        self.trackingSwitch.on = number.boolValue; [self changeTracking];
        return @{ @"control":control, @"value":@(number.boolValue) };
    }
    if ([control isEqual:@"peaking"]) {
        if (!number || !self.peakingSwitch.enabled) { if (error) *error = @"Peaking está indisponível nesta sessão."; return nil; }
        self.peakingSwitch.on = number.boolValue; [self changePeaking];
        return @{ @"control":control, @"value":@(number.boolValue) };
    }
    if ([control isEqual:@"peakingThreshold"]) {
        if (!number) { if (error) *error = @"peakingThreshold requer um número."; return nil; }
        double threshold = number.doubleValue;
        if (!isfinite(threshold) || threshold < self.thresholdSlider.minimumValue || threshold > self.thresholdSlider.maximumValue) {
            if (error) *error = @"peakingThreshold deve ficar entre 0.03 e 0.6."; return nil;
        }
        self.thresholdSlider.value = threshold; [self changePeaking];
        return @{ @"control":control, @"value":@(threshold) };
    }
    if (error) *error = @"Controle desconhecido. Consulte README/API-REMOTE.md.";
    return nil;
}

- (void)executeRemoteCommand:(NSDictionary *)body requestID:(NSString *)requestID
    completion:(M7RemoteResponse)completion {
    NSString *command = [body[@"command"] isKindOfClass:NSString.class] ? body[@"command"] : @"";
    if (!command.length) { completion(400, @{ @"ok":@NO, @"error":@"O campo command é obrigatório." }); return; }
    if ([command isEqual:@"set"]) {
        NSString *control = [body[@"control"] isKindOfClass:NSString.class] ? body[@"control"] : @"";
        id value = body[@"value"];
        NSString *error = nil;
        NSDictionary *result = control.length && value ? [self applyRemoteControl:control value:value error:&error] : nil;
        if (!result) { completion(409, @{ @"ok":@NO, @"error":error ?: @"control e value são obrigatórios." }); return; }
        [self message:[NSString stringWithFormat:@"Remoto: %@ atualizado.", control]];
        completion(202, @{ @"ok":@YES, @"accepted":@YES, @"command":command, @"result":result });
        return;
    }
    if ([command isEqual:@"capture"] || [command isEqual:@"photo.capture"] ||
        [command hasPrefix:@"record."]) {
        BOOL photoOnly = [command isEqual:@"photo.capture"];
        BOOL recordCommand = [command hasPrefix:@"record."];
        BOOL validRecordAction = [command isEqual:@"record.start"] || [command isEqual:@"record.stop"] ||
            [command isEqual:@"record.toggle"];
        if (photoOnly && self.videoModeActive) { completion(409, @{ @"ok":@NO, @"error":@"photo.capture requer modo Foto." }); return; }
        if (recordCommand && (!validRecordAction || !self.videoModeActive)) {
            completion(409, @{ @"ok":@NO, @"error":@"O comando de gravação requer modo Vídeo." }); return;
        }
        if ([command isEqual:@"record.start"] && self.videoRecording) {
            completion(409, @{ @"ok":@NO, @"error":@"A gravação já está ativa." }); return;
        }
        if ([command isEqual:@"record.stop"] && !self.videoRecording) {
            completion(409, @{ @"ok":@NO, @"error":@"Não há gravação ativa." }); return;
        }
        if (!self.shutterButton.enabled && !self.videoRecording) {
            completion(409, @{ @"ok":@NO, @"error":@"O disparador está bloqueado; consulte state." }); return;
        }
        [self capture];
        completion(202, @{ @"ok":@YES, @"accepted":@YES, @"command":command });
        return;
    }
    if ([command isEqual:@"webcam.start"] || [command isEqual:@"webcam.stop"]) {
        BOOL start = [command isEqual:@"webcam.start"];
        if (start && (!self.configured || self.closing || self.captureBusy || self.comparisonActive ||
            self.videoRecording || self.videoProcessing || self.pendingPhoto)) {
            completion(409, @{ @"ok":@NO,
                @"error":@"A sessão da câmera não está livre para iniciar a webcam." });
            return;
        }
        BOOL changed = self.webcamSwitch.on != start;
        self.webcamSwitch.on = start;
        if (changed) [self changeWebcam];
        completion(202, @{ @"ok":@YES, @"accepted":@YES, @"command":command,
            @"changed":@(changed), @"captureMode":start ? @"video" :
                (self.videoModeActive ? @"video" : @"photo"),
            @"format":self.webcamVertical ? @"vertical" : @"horizontal" });
        return;
    }
    if ([command isEqual:@"photo.retry"] || [command isEqual:@"videos.retry"]) {
        dispatch_async(self.sessionQueue, ^{
            if ([command isEqual:@"photo.retry"]) {
                if (!self.pendingPhoto) { completion(409, @{ @"ok":@NO, @"error":@"Não há foto pendente." }); return; }
                [self savePhotoToPhotos:self.pendingPhoto];
            } else {
                if (!self.pendingVideos.count || self.videoRecording || self.videoProcessing) {
                    completion(409, @{ @"ok":@NO, @"error":@"Não há vídeos prontos para repetir agora." }); return;
                }
                [self retryPendingVideos];
            }
            completion(202, @{ @"ok":@YES, @"accepted":@YES, @"command":command });
        });
        return;
    }
    if ([command isEqual:@"close"]) {
        if (self.videoRecording || self.videoProcessing || self.captureBusy) {
            completion(409, @{ @"ok":@NO, @"error":@"Finalize a captura ou o processamento antes de fechar." }); return;
        }
        completion(202, @{ @"ok":@YES, @"accepted":@YES, @"command":command });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/3), dispatch_get_main_queue(), ^{ [self close]; });
        return;
    }
    completion(400, @{ @"ok":@NO, @"error":@"Comando desconhecido. Consulte README/API-REMOTE.md.",
        @"command":command, @"requestID":requestID ?: @"" });
}

- (NSURL *)outputDirectory {
    return self.storage.directory;
}

// Called only on sessionQueue. The file survives a process crash/relaunch.
- (void)recordCaptureStage:(NSString *)stage details:(NSDictionary *)details {
    if (!self.captureTrace) self.captureTrace = [NSMutableDictionary new];
    NSMutableArray *events = self.captureTrace[@"events"];
    if (!events) { events = [NSMutableArray new]; self.captureTrace[@"events"] = events; }
    [events addObject:@{@"stage":stage, @"time":@(NSDate.date.timeIntervalSince1970), @"details":details ?: @{}}];
    if (events.count > 24) [events removeObjectAtIndex:0];
    self.captureTrace[@"version"] = @"0.7.7";
    self.captureTrace[@"controllerID"] = self.controllerID;
    self.captureTrace[@"sessionID"] = self.sessionID;
    self.captureTrace[@"processID"] = @(getpid());
    self.captureTrace[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
    self.captureTrace[@"storage"] = self.storage.attempts ?: @[];
    NSError *error = nil;
    [self.captureTrace removeObjectForKey:@"diagnosticWriteError"];
    [self.storage writeJSON:self.captureTrace filename:@"ultima-captura.json" error:&error];
    if (error) self.captureTrace[@"diagnosticWriteError"] = error.localizedDescription;
    if (error) NSLog(@"[Manual7] Capture diagnostic: %@", error);
}

- (void)finishCaptureWithError:(NSError *)error {
    self.captureBusy = NO; self.captureData = nil; self.captureMetadata = nil; self.captureResult = nil;
    [self recordCaptureStage:@"error" details:M7ErrorDetails(error)];
    [self message:[NSString stringWithFormat:@"%@ (%ld) · Detalhes em Exportar → Ver diagnóstico.", error.localizedDescription ?: @"Falha de captura", (long)error.code]];
    dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = YES; self.shareButton.enabled = YES; });
    [self completeComparison:@"captureFailed"];
}

- (NSError *)captureExceptionError:(NSException *)exception {
    return [NSError errorWithDomain:@"Manual7.CaptureException" code:1 userInfo:@{
        NSLocalizedDescriptionKey:[NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @"Captura recusada"]}];
}

- (void)updateSizeControl {
    self.sizeButton.enabled = self.captureAvailable && !self.videoModeActive && !self.rawSwitch.on;
    NSString *title = self.rawSwitch.on ? @"Original do sensor" : @"Original";
    if (!self.rawSwitch.on) {
        double width = [self.limits[@"nativeWidth"] doubleValue], height = [self.limits[@"nativeHeight"] doubleValue];
        double scale = self.jpegLongEdge && MAX(width, height) > 0 ? MIN(1.0, self.jpegLongEdge / MAX(width, height)) : 1.0;
        NSString *label = self.jpegLongEdge ? @"JPEG" : @"Original";
        if (width > 0 && height > 0) title = [NSString stringWithFormat:@"%@ · %.0f × %.0f", label, round(width*scale), round(height*scale)];
    }
    [self.sizeButton setTitle:title forState:UIControlStateNormal];
}

- (void)chooseJPEGSize {
    if (self.rawSwitch.on || !self.captureAvailable) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Tamanho do JPEG"
        message:@"Original preserva a foto capturada. Os demais tamanhos reduzem a imagem mantendo a proporção."
        preferredStyle:UIAlertControllerStyleActionSheet];
    double width = [self.limits[@"nativeWidth"] doubleValue], height = [self.limits[@"nativeHeight"] doubleValue];
    for (NSNumber *number in @[@0, @3264, @2560, @2048, @1600, @1280]) {
        NSUInteger edge = number.unsignedIntegerValue;
        if (edge && edge >= MAX(width, height)) continue;
        double scale = edge && MAX(width, height) > 0 ? edge / MAX(width, height) : 1;
        NSString *label = edge ? @"JPEG" : @"Original";
        NSString *title = [NSString stringWithFormat:@"%@ · %.0f × %.0f", label, round(width*scale), round(height*scale)];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            self.jpegLongEdge = edge; [self updateSizeControl];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.sizeButton;
    [self presentViewController:menu animated:YES completion:nil];
}

// RAW capture can require extra buffers on older devices. Apple documents this
// preparation as optional, but doing it after every input/topology change makes
// allocation failures visible before the shutter request reaches the sensor.
- (void)prepareRAWPipeline {
    NSUInteger revision = ++self.rawPreparationRevision;
    NSError *error = nil;
    NSDictionary *compatibility = nil;
    AVCapturePhotoSettings *raw = [self.controls rawSettingsForOutput:self.photoOutput
        includeProcessedJPEG:NO diagnostic:&compatibility error:&error];
    if (!raw) {
        self.rawPreparationPending = NO;
        self.rawPrepared = NO;
        self.rawPreparationReport = @{ @"prepared":@NO, @"revision":@(revision),
            @"compatibility":compatibility ?: @{}, @"error":M7ErrorDetails(error) };
        [self recordSessionEvent:@"rawPreparationUnavailable" details:self.rawPreparationReport];
        return;
    }
    NSMutableArray<AVCapturePhotoSettings *> *settings = [NSMutableArray arrayWithObject:raw];
    AVCapturePhotoSettings *rawJPEG = [self.controls rawSettingsForOutput:self.photoOutput
        includeProcessedJPEG:YES diagnostic:nil error:nil];
    if (rawJPEG) [settings addObject:rawJPEG];
    self.rawPreparationPending = YES;
    self.rawPrepared = NO;
    self.rawPreparationReport = @{ @"prepared":@NO, @"pending":@YES,
        @"revision":@(revision), @"settingsCount":@(settings.count),
        @"compatibility":compatibility ?: @{} };
    [self recordSessionEvent:@"rawPreparationRequested" details:self.rawPreparationReport];
    __weak typeof(self) weakSelf = self;
    dispatch_queue_t callbackQueue = self.sessionQueue;
    @try {
        [self.photoOutput setPreparedPhotoSettingsArray:settings completionHandler:^(BOOL prepared, NSError *prepareError) {
            dispatch_async(callbackQueue, ^{
                typeof(self) owner = weakSelf;
                if (!owner || revision != owner.rawPreparationRevision) return;
                owner.rawPreparationPending = NO;
                owner.rawPrepared = prepared;
                owner.rawPreparationReport = @{ @"prepared":@(prepared), @"pending":@NO,
                    @"revision":@(revision), @"settingsCount":@(settings.count),
                    @"compatibility":compatibility ?: @{}, @"error":M7ErrorDetails(prepareError) };
                [owner recordSessionEvent:@"rawPreparationFinished" details:owner.rawPreparationReport];
            });
        }];
    } @catch (NSException *exception) {
        self.rawPreparationPending = NO;
        self.rawPrepared = NO;
        error = [self captureExceptionError:exception];
        self.rawPreparationReport = @{ @"prepared":@NO, @"pending":@NO,
            @"revision":@(revision), @"settingsCount":@(settings.count),
            @"compatibility":compatibility ?: @{}, @"error":M7ErrorDetails(error) };
        [self recordSessionEvent:@"rawPreparationException" details:self.rawPreparationReport];
    }
}

- (BOOL)selectDevice:(AVCaptureDeviceType)type error:(NSError **)error {
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithDeviceType:type mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
    if (!device) {
        if (error) *error = [NSError errorWithDomain:@"Manual7" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Lente indisponível."}];
        return NO;
    }
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:error];
    if (!input) return NO;
    [self.session beginConfiguration];
    AVCaptureDeviceInput *old = self.input;
    if (old) [self.session removeInput:old];
    if (![self.session canAddInput:input]) {
        if (old && [self.session canAddInput:old]) [self.session addInput:old];
        [self.session commitConfiguration];
        if (error) *error = [NSError errorWithDomain:@"Manual7" code:3 userInfo:@{NSLocalizedDescriptionKey: @"A sessão recusou a lente."}];
        return NO;
    }
    [self.session addInput:input]; self.input = input;
    [self.session commitConfiguration];
    self.controls = [[M7DeviceControls alloc] initWithDevice:device];
    if (self.videoModeActive) {
        [self.session beginConfiguration];
        NSDictionary *videoFormat = [self.controls configureVideoFormatAtFPS:30 error:error];
        [self.session commitConfiguration];
        if (!videoFormat) return NO;
        self.videoFormatDiagnostic = videoFormat;
    } else self.videoFormatDiagnostic = nil;
    if ([device lockForConfiguration:error]) {
        device.videoZoomFactor = 1.0;
        [device unlockForConfiguration];
    } else return NO;
    [self.controls enableAutoExposure:nil]; [self.controls enableAutoFocus:nil];
    [self.controls setExposureBiasThirds:0 completion:nil error:nil];
    self.pendingExposure = NO; self.pendingFocus = NO;
    ++self.exposureRevision; ++self.focusRevision;
    for (AVCaptureOutput *output in @[self.photoOutput, self.videoOutput]) {
        AVCaptureConnection *c = [output connectionWithMediaType:AVMediaTypeVideo];
        if (c.isVideoOrientationSupported) c.videoOrientation = output == self.videoOutput ?
            M7VideoOrientationForMount(self.cameraMount) : AVCaptureVideoOrientationPortrait;
        if (c.isVideoStabilizationSupported) c.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeOff;
    }
    // A new input recreates the data output connection, enabled by default.
    [self updateVideoOutputDemand];
    NSMutableDictionary *limits = [self.controls.capabilities mutableCopy];
    CMVideoDimensions native = device.activeFormat.highResolutionStillImageDimensions;
    limits[@"nativeWidth"] = @(native.width); limits[@"nativeHeight"] = @(native.height);
    int selected = 0;
    m7_shutter_nearest(CMTimeGetSeconds(device.exposureDuration),
        CMTimeGetSeconds(device.activeFormat.minExposureDuration),
        CMTimeGetSeconds(device.activeFormat.maxExposureDuration), &selected);
    float isoPosition = (log(device.ISO) - log(device.activeFormat.minISO)) /
        fmax(1e-9, log(device.activeFormat.maxISO) - log(device.activeFormat.minISO));
    NSDictionary *rawCompatibility = [self.controls rawCompatibilityForOutput:self.photoOutput];
    BOOL raw = [rawCompatibility[@"selectedRawFormat"] unsignedIntValue] != 0;
    NSMutableDictionary *diagnostic = [limits mutableCopy];
    diagnostic[@"systemVersion"] = UIDevice.currentDevice.systemVersion;
    diagnostic[@"rawFormats"] = self.photoOutput.availableRawPhotoPixelFormatTypes;
    diagnostic[@"rawCompatibility"] = rawCompatibility;
    diagnostic[@"version"] = @"0.7.7";
    self.lensDiagnostic = diagnostic;
    [self prepareRAWPipeline];
    [self.storage writeJSON:diagnostic filename:@"diagnostico.json" error:nil];
    float focus = device.lensPosition;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.limits = limits;
        self.exposureMode.selectedSegmentIndex = 0; self.focusMode.selectedSegmentIndex = 0;
        self.lens.selectedSegmentIndex = [type isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera] ? 1 : 0;
        self.isoSlider.value = isoPosition;
        self.shutterSlider.minimumValue = [limits[@"firstShutterIndex"] intValue];
        self.shutterSlider.maximumValue = [limits[@"lastShutterIndex"] intValue];
        self.shutterSlider.value = selected;
        self.focusSlider.value = focus;
        self.evStepper.minimumValue = ceil([limits[@"minEV"] doubleValue] * 3);
        self.evStepper.maximumValue = floor([limits[@"maxEV"] doubleValue] * 3);
        self.evStepper.value = 0;
        self.rawSwitch.enabled = raw; self.rawSwitch.on = raw;
        [self updateSizeControl];
        self.peakingView.image = nil;
        self.shareButton.enabled = YES;
    });
    return YES;
}

- (void)changeVideoFormat {
    [self updateReframeGuide];
    NSString *name = self.videoFormat.selectedSegmentIndex == 0 ? @"horizontal16x9" :
        self.videoFormat.selectedSegmentIndex == 1 ? @"vertical9x16" : @"horizontalAndVertical";
    dispatch_async(self.sessionQueue, ^{ [self recordSessionEvent:@"reframeSelection" details:@{@"mode":name}]; });
}

- (void)changeTracking {
    BOOL enabled = self.trackingSwitch.on;
    self.trackingEnabled = enabled;
    self.trackingPending = NO;
    self.trackingCenter = CGPointMake(.5, .5);
    self.trackingDetected = NO;
    [self updateReframeGuide];
    dispatch_async(self.trackingQueue, ^{ [self.subjectTracker reset]; });
    dispatch_async(self.videoQueue, ^{ self.lastTrackingTime = 0; });
    dispatch_async(self.sessionQueue, ^{
        [self recordControlChange:@"subjectTracking" details:@{ @"enabled":@(enabled),
            @"detector":@"humanUpperBodyWithFaceFallback", @"analysisHz":@5 }];
    });
    [self message:enabled ? @"Rastreamento de pessoa ativo; o círculo fica verde ao detectar."
        : @"Rastreamento desligado; o Reframe voltou ao centro."];
}

- (void)finishPairingUI:(NSString *)message {
    dispatch_async(self.sessionQueue, ^{ [self updateVideoOutputDemand]; });
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pairButton setTitle:@"Ler QR do PC" forState:UIControlStateNormal];
        [self enableControls:self.configured && self.session.isRunning];
        if (message.length) [self message:message];
    });
}

- (void)cancelPairing:(NSString *)reason {
    BOOL wasActive = self.pairingScanning || self.pairingSubmitting;
    ++self.pairingGeneration;
    self.pairingScanning = NO;
    self.pairingAnalyzing = NO;
    self.pairingSubmitting = NO;
    dispatch_async(self.pairingQueue, ^{ [self.pairingManager cancel]; });
    if (wasActive) dispatch_async(self.sessionQueue, ^{
        [self recordSessionEvent:@"pairingCancelled" details:@{ @"reason":reason ?: @"" }];
    });
    [self finishPairingUI:[reason isEqual:@"user"] ? @"Leitura do QR cancelada." : nil];
}

- (void)togglePairingScan {
    if (self.pairingScanning || self.pairingSubmitting) { [self cancelPairing:@"user"]; return; }
    self.pairButton.enabled = NO;
    ++self.pairingGeneration;
    dispatch_async(self.sessionQueue, ^{
        if (!self.configured || !self.session.isRunning || self.closing || self.captureBusy) {
            [self recordSessionEvent:@"pairingScanRejected" details:[self sessionDiagnostic]];
            [self finishPairingUI:@"A câmera precisa estar pronta para ler o QR."];
            return;
        }
        if (![self.openSSHStatus[@"serviceReachable"] boolValue]) {
            [self recordSessionEvent:@"pairingScanRejected" details:@{ @"reason":@"openSSHUnavailable",
                @"openSSH":self.openSSHStatus ?: @{} }];
            [self finishPairingUI:@"Aguarde a linha Remoto mostrar uma porta SSH ativa."];
            return;
        }
        if (!self.remoteServer.isRunning || !self.remoteSocketPath.length || !self.webcamSocketPath.length) {
            [self recordSessionEvent:@"pairingScanRejected" details:@{ @"reason":@"remoteAPIUnavailable",
                @"remoteServer":self.remoteServer.snapshot ?: @{},
                @"bindAttempts":self.remoteBindAttempts ?: @[] }];
            [self finishPairingUI:@"A API remota não iniciou. Abra Exportar → Ver diagnóstico."];
            return;
        }
        BOOL outputReady = [self.session.outputs containsObject:self.videoOutput];
        if (!outputReady && !self.videoModeActive) outputReady = [self configurePeakingOutput:YES];
        if (!outputReady) {
            [self recordSessionEvent:@"pairingScanRejected" details:@{ @"reason":@"videoOutputUnavailable",
                @"session":[self sessionDiagnostic] }];
            [self finishPairingUI:@"Não foi possível ativar o leitor QR. Veja o diagnóstico."];
            return;
        }
        dispatch_sync(self.videoQueue, ^{
            self.pairingStartedAt = CACurrentMediaTime();
            self.lastPairingScanTime = 0;
        });
        self.pairingScanning = YES;
        self.pairingAnalyzing = NO;
        [self updateVideoOutputDemand];
        BOOL usageDeclared = [NSBundle.mainBundle objectForInfoDictionaryKey:
            @"NSLocalNetworkUsageDescription"] != nil;
        [self recordSessionEvent:@"pairingScanStarted" details:@{ @"timeoutSeconds":@30,
            @"analysisHz":@3, @"localNetworkUsageDeclared":@(usageDeclared) }];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.pairButton setTitle:@"Cancelar QR" forState:UIControlStateNormal];
            self.pairButton.enabled = YES;
            [self message:@"Aponte a câmera para o QR exibido pelo script Linux."];
        });
    });
}

- (void)schedulePairingForSampleBuffer:(CMSampleBufferRef)sample {
    if (!self.pairingScanning || self.pairingAnalyzing) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.pairingStartedAt >= 30) {
        self.pairingScanning = NO;
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:@"pairingScanTimedOut" details:@{ @"timeoutSeconds":@30 }];
        });
        [self finishPairingUI:@"QR não encontrado em 30 segundos. Tente novamente."];
        return;
    }
    if (now - self.lastPairingScanTime < (1.0/3.0)) return;
    self.lastPairingScanTime = now;
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    if (!pixel) return;
    self.pairingAnalyzing = YES;
    NSUInteger generation = self.pairingGeneration;
    CVPixelBufferRetain(pixel);
    dispatch_async(self.pairingQueue, ^{
        NSError *scanError = nil;
        NSDictionary *pairing = [self.pairingManager pairingPayloadFromPixelBuffer:pixel error:&scanError];
        CVPixelBufferRelease(pixel);
        self.pairingAnalyzing = NO;
        if (!self.pairingScanning || generation != self.pairingGeneration) return;
        if (scanError) {
            self.pairingScanning = NO;
            dispatch_async(self.sessionQueue, ^{
                [self recordSessionEvent:@"pairingCodeRejected" details:@{ @"error":M7ErrorDetails(scanError) }];
            });
            [self finishPairingUI:scanError.localizedDescription];
            return;
        }
        if (!pairing) return;
        self.pairingScanning = NO;
        self.pairingSubmitting = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.pairButton setTitle:@"Conectando…" forState:UIControlStateNormal];
            self.pairButton.enabled = NO;
            [self message:[NSString stringWithFormat:@"QR de %@ reconhecido. Conectando…",
                pairing[@"name"] ?: @"notebook"]];
        });
        dispatch_async(self.sessionQueue, ^{
            NSNumber *preferred = self.openSSHStatus[@"preferredPort"] ?: @0;
            NSArray *ports = self.openSSHStatus[@"openPorts"] ?: @[];
            [self recordSessionEvent:@"pairingCodeRecognized" details:@{
                @"computerName":pairing[@"name"] ?: @"", @"callbackHost":pairing[@"host"] ?: @"",
                @"callbackPort":pairing[@"port"] ?: @0, @"preferredSSHPort":preferred,
                @"availableSSHPorts":ports }];
            dispatch_async(self.pairingQueue, ^{
                [self.pairingManager submitPairing:pairing pin:self.remotePIN preferredSSHPort:preferred
                    availableSSHPorts:ports apiSocketPath:self.remoteSocketPath
                    webcamSocketPath:self.webcamSocketPath
                    apiBridgePort:@27839 webcamBridgePort:@27840
                    completion:^(NSDictionary *response, NSError *error) {
                    if (generation != self.pairingGeneration) return;
                    self.pairingSubmitting = NO;
                    dispatch_async(self.sessionQueue, ^{
                        [self recordSessionEvent:error ? @"pairingSubmitFailed" : @"pairingAccepted"
                            details:@{ @"computerName":pairing[@"name"] ?: @"",
                                @"callbackHost":pairing[@"host"] ?: @"",
                                @"callbackPort":pairing[@"port"] ?: @0,
                                @"response":response ?: @{}, @"error":M7ErrorDetails(error) }];
                    });
                    [self finishPairingUI:error ? [NSString stringWithFormat:
                        @"Pareamento falhou: %@ · veja o diagnóstico.", error.localizedDescription]
                        : @"Notebook reconhecido. Autorize o SSH no Linux, se solicitado."];
                }];
            });
        });
    });
}

// Never waits on webcamQueue: a sync there stalled the session queue for a
// whole JPEG encode on every state poll. The server snapshot takes its own
// lock and lastWebcamError is atomic.
- (NSDictionary *)webcamSnapshot {
    NSDictionary *server = self.webcamServer.snapshot ?: @{};
    NSDictionary *lastError = self.lastWebcamError ?: @{};
    BOOL vertical = self.webcamVertical;
    M7CameraMount mount = self.cameraMount;
    NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    CGSize h264Size = M7WebcamOutputSize(M7WebcamCodecH264, vertical, mount != M7CameraMountPortrait);
    double averageEncodeMilliseconds = self.webcamEncodedFrames ?
        self.webcamEncodeMillisecondsTotal / self.webcamEncodedFrames : 0;
    return @{ @"requested":@(self.webcamRequested), @"enabled":@(self.webcamEnabled),
        @"encoding":@(self.webcamEncoding),
        @"format":vertical ? @"vertical" : @"horizontal",
        @"width":vertical ? @720 : @1280, @"height":vertical ? @1280 : @720,
        @"targetFPS":@(M7WebcamTargetFPS), @"jpegQuality":@(M7WebcamJPEGQuality), @"videoOnly":@YES,
        @"captureModeRequired":@"video", @"captureModeActive":@(self.videoModeActive),
        @"usesCameraControls":@YES, @"trackingReframe":@(self.trackingEnabled),
        @"inputFrames":@(self.webcamInputFrames), @"encodedFrames":@(self.webcamEncodedFrames),
        @"busyDrops":@(self.webcamBusyDrops), @"screenKeptAwake":@(self.webcamHoldsIdleTimer),
        @"cameraMount":M7CameraMountName(mount),
        @"thermal":@{ @"state":M7ThermalName(thermal), @"maxFPS":@(M7ThermalMaxWebcamFPS(thermal)),
            @"drops":@(self.webcamThermalDrops) },
        @"lastEncodeMilliseconds":@(self.webcamLastEncodeMilliseconds),
        @"averageEncodeMilliseconds":@(averageEncodeMilliseconds),
        @"lastError":lastError, @"server":server,
        @"encoder":@{ @"backend":self.webcamEncoder.backend ?: @"",
            @"hardwareStatus":@(self.webcamEncoder.hardwareStatus) },
        @"codecs":self.webcamEncoder.h264Available ? @[@"mjpeg", @"h264"] : @[@"mjpeg"],
        @"h264":@{ @"available":@(self.webcamEncoder.h264Available),
            @"status":@(self.webcamEncoder.h264Status), @"route":@"/v1/webcam.h264",
            @"width":@(h264Size.width), @"height":@(h264Size.height),
            @"bitRate":@(M7WebcamH264BitRate(h264Size)) } };
}

// Main queue. Rotating the data output while a webcam client or the video
// writer consumes it would change the frame size under them.
- (void)changeCameraMount {
    NSInteger index = self.mountControl.selectedSegmentIndex;
    if (self.webcamRequested || self.webcamEnabled || self.videoRecording || self.videoProcessing ||
        index < M7CameraMountLandscape || index > M7CameraMountPortrait) {
        self.mountControl.selectedSegmentIndex = self.cameraMount;
        [self message:@"Pare a webcam e a gravação antes de mudar a montagem."];
        return;
    }
    M7CameraMount mount = (M7CameraMount)index;
    if (mount == self.cameraMount) return;
    self.cameraMount = mount;
    [NSUserDefaults.standardUserDefaults setInteger:mount forKey:M7CameraMountDefaultsKey];
    // The tracked center belongs to the previous buffer orientation.
    self.trackingCenter = CGPointMake(.5, .5);
    self.peakingView.image = nil;
    [self updateReframeGuide];
    dispatch_async(self.sessionQueue, ^{
        AVCaptureConnection *connection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
        if (connection.isVideoOrientationSupported)
            connection.videoOrientation = M7VideoOrientationForMount(mount);
        [self recordSessionEvent:@"cameraMountChanged" details:@{ @"mount":M7CameraMountName(mount),
            @"videoOrientation":@(connection.videoOrientation) }];
    });
    [self message:mount == M7CameraMountPortrait ? @"Montagem em retrato: 9:16 nativo." :
        mount == M7CameraMountLandscape ? @"Montagem em paisagem, botão Home à direita: 16:9 nativo." :
        @"Montagem em paisagem, botão Home à esquerda: 16:9 nativo."];
}

- (void)changeWebcamFormat {
    BOOL vertical = self.webcamFormat.selectedSegmentIndex == 1;
    self.webcamVertical = vertical;
    NSString *format = vertical ? @"vertical" : @"horizontal";
    dispatch_async(self.sessionQueue, ^{
        [self recordControlChange:@"webcamFormat" details:@{ @"format":format,
            @"width":vertical ? @720 : @1280,
            @"height":vertical ? @1280 : @720 }];
    });
    [self message:[NSString stringWithFormat:@"Webcam %@; o próximo frame usa o novo recorte.",
        vertical ? @"9:16" : @"16:9"]];
}

// Main queue only. Auto-lock resigns the Camera app, which stops the webcam,
// so the screen stays awake while it streams; Camera's own value is restored.
- (void)keepScreenAwakeForWebcam:(BOOL)awake {
    if (awake == self.webcamHoldsIdleTimer) return;
    UIApplication *application = UIApplication.sharedApplication;
    if (awake) self.idleTimerWasDisabled = application.idleTimerDisabled;
    application.idleTimerDisabled = awake || self.idleTimerWasDisabled;
    self.webcamHoldsIdleTimer = awake;
}

- (void)failWebcamStartOnSessionQueue:(NSString *)reason error:(NSError *)error {
    self.webcamRequested = NO; self.webcamEnabled = NO;
    self.lastWebcamError = error ? M7ErrorDetails(error) : @{};
    [self recordSessionEvent:@"webcamStartFailed" details:@{
        @"reason":reason ?: @"unknown", @"error":M7ErrorDetails(error),
        @"captureMode":self.videoModeActive ? @"video" : @"photo",
        @"session":[self sessionDiagnostic] }];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.webcamSwitch.on = NO;
        [self keepScreenAwakeForWebcam:NO];
        [self enableControls:self.configured && self.session.isRunning];
        [self message:[NSString stringWithFormat:@"Webcam indisponível: %@",
            error.localizedDescription ?: @"o modo Vídeo não ficou pronto"]];
    });
}

// sessionQueue only. Starting the socket before Video mode finishes changing the
// AVCaptureSession leaves the live sample-buffer client attached to old topology.
- (void)startWebcamServerForActiveVideo {
    if (!self.webcamRequested) return;
    BOOL outputReady = self.configured && self.videoModeActive && self.session.isRunning &&
        [self.session.outputs containsObject:self.videoOutput];
    if (!outputReady) {
        [self failWebcamStartOnSessionQueue:@"videoModeOrOutputUnavailable" error:nil];
        return;
    }
    self.webcamInputFrames = 0; self.webcamEncodedFrames = 0; self.webcamBusyDrops = 0;
    self.webcamThermalDrops = 0;
    self.webcamEncodeMillisecondsTotal = 0; self.webcamLastEncodeMilliseconds = 0;
    self.lastWebcamTime = 0;
    dispatch_async(self.webcamQueue, ^{
        if (!self.webcamRequested) return;
        NSError *error = nil;
        BOOL ready = [self.webcamServer start:&error];
        if (ready && !self.webcamRequested) { [self.webcamServer stop]; ready = NO; }
        NSDictionary *snapshot = self.webcamServer.snapshot ?: @{};
        self.lastWebcamError = error ? M7ErrorDetails(error) : @{};
        if (!ready) self.webcamRequested = NO;
        self.webcamEnabled = ready;
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:ready ? @"webcamStarted" : @"webcamStartFailed"
                details:@{ @"server":snapshot, @"error":M7ErrorDetails(error),
                    @"captureMode":self.videoModeActive ? @"video" : @"photo",
                    @"targetFPS":@(M7WebcamTargetFPS),
                    @"format":self.webcamVertical ? @"vertical" : @"horizontal" }];
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.webcamRequested) return;
            self.webcamSwitch.on = ready;
            [self keepScreenAwakeForWebcam:ready];
            [self enableControls:self.configured && self.session.isRunning];
            [self message:ready ? @"Webcam pronta em modo Vídeo a até 30 fps." :
                [NSString stringWithFormat:@"Webcam indisponível: %@",
                    error.localizedDescription ?: @"erro no socket"]];
        });
    });
}

- (void)changeWebcam {
    BOOL enabled = self.webcamSwitch.on;
    self.webcamRequested = enabled;
    if (!enabled) {
        self.webcamEnabled = NO;
        [self keepScreenAwakeForWebcam:NO];
        dispatch_async(self.webcamQueue, ^{
            [self.webcamServer stop];
            NSDictionary *snapshot = self.webcamServer.snapshot ?: @{};
            dispatch_async(self.sessionQueue, ^{
                [self recordSessionEvent:@"webcamStopped" details:@{
                    @"server":snapshot, @"inputFrames":@(self.webcamInputFrames),
                    @"encodedFrames":@(self.webcamEncodedFrames),
                    @"busyDrops":@(self.webcamBusyDrops) }];
            });
            dispatch_async(dispatch_get_main_queue(), ^{ [self message:@"Webcam desligada."]; });
        });
        return;
    }
    self.webcamSwitch.enabled = NO;
    dispatch_async(self.sessionQueue, ^{
        if (!self.webcamRequested) return;
        if (!self.videoModeActive) {
            [self recordSessionEvent:@"webcamVideoModeRequested" details:@{
                @"previousCaptureMode":@"photo", @"targetFPS":@(M7WebcamTargetFPS) }];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.captureMode.selectedSegmentIndex = 1;
                self.rawRow.hidden = YES; self.sizeRow.hidden = YES;
                self.videoFormatRow.hidden = NO; self.trackingRow.hidden = NO;
                [self updateReframeGuide]; [self enableControls:NO];
                [self message:@"Preparando modo Vídeo para a webcam…"];
            });
            [self configureSessionForVideo:YES];
            return;
        }
        [self startWebcamServerForActiveVideo];
    });
}

- (void)recordWebcamEncodeError:(NSError *)error {
    self.lastWebcamError = M7ErrorDetails(error);
    CFTimeInterval errorNow = CACurrentMediaTime();
    if (errorNow - self.lastWebcamErrorLogTime < 2) return;
    self.lastWebcamErrorLogTime = errorNow;
    dispatch_async(self.sessionQueue, ^{
        [self recordSessionEvent:@"webcamEncodeError" details:M7ErrorDetails(error)];
    });
}

// Encodes only what the connected clients asked for: JPEG for MJPEG clients,
// H.264 for H.264 clients, both when both are attached.
- (void)scheduleWebcamForSampleBuffer:(CMSampleBufferRef)sample {
    if (!self.webcamEnabled || self.webcamServer.clientCount == 0) return;
    ++self.webcamInputFrames;
    if (self.webcamEncoding) { ++self.webcamBusyDrops; return; }
    CFTimeInterval now = CACurrentMediaTime();
    double maxFPS = M7ThermalMaxWebcamFPS(NSProcessInfo.processInfo.thermalState);
    // 2 ms of slack keeps a 33 ms camera cadence from skipping two frames in a row.
    if (maxFPS > 0 && now - self.lastWebcamTime < 1.0 / maxFPS - .002) { ++self.webcamThermalDrops; return; }
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    if (!pixel) return;
    self.lastWebcamTime = now; self.webcamEncoding = YES;
    BOOL vertical = self.webcamVertical;
    CGPoint center = self.trackingEnabled ? self.trackingCenter : CGPointMake(.5, .5);
    CMTime presentationTime = CMSampleBufferGetPresentationTimeStamp(sample);
    BOOL landscapeSource = CVPixelBufferGetWidth(pixel) > CVPixelBufferGetHeight(pixel);
    CVPixelBufferRetain(pixel);
    dispatch_async(self.webcamQueue, ^{
        @autoreleasepool {
            CFTimeInterval encodeStarted = CACurrentMediaTime();
            BOOL encoded = NO;
            if ([self.webcamServer clientCountForCodec:M7WebcamCodecMJPEG]) {
                NSError *error = nil;
                NSData *jpeg = [self.webcamEncoder JPEGDataForPixelBuffer:pixel vertical:vertical
                    normalizedCenter:center error:&error];
                CGSize size = M7WebcamOutputSize(M7WebcamCodecMJPEG, vertical, landscapeSource);
                if (jpeg.length && self.webcamEnabled) {
                    encoded = YES;
                    [self.webcamServer publishJPEG:jpeg width:(NSUInteger)size.width
                        height:(NSUInteger)size.height];
                } else if (error) [self recordWebcamEncodeError:error];
            }
            if ([self.webcamServer clientCountForCodec:M7WebcamCodecH264]) {
                NSError *error = nil;
                BOOL keyframe = NO;
                NSData *accessUnit = [self.webcamEncoder H264AccessUnitForPixelBuffer:pixel
                    vertical:vertical normalizedCenter:center presentationTime:presentationTime
                    forceKeyframe:[self.webcamServer consumeKeyframeRequest]
                    keyframe:&keyframe error:&error];
                CGSize size = M7WebcamOutputSize(M7WebcamCodecH264, vertical, landscapeSource);
                if (accessUnit.length && self.webcamEnabled) {
                    encoded = YES;
                    [self.webcamServer publishH264:accessUnit keyframe:keyframe
                        width:(NSUInteger)size.width height:(NSUInteger)size.height];
                } else if (error) {
                    [self recordWebcamEncodeError:error];
                    // Clients fall back to MJPEG once the stream closes.
                    if (!self.webcamEncoder.h264Available)
                        [self.webcamServer closeClientsForCodec:M7WebcamCodecH264];
                }
            }
            CVPixelBufferRelease(pixel);
            double encodeMilliseconds = (CACurrentMediaTime() - encodeStarted) * 1000.0;
            self.webcamLastEncodeMilliseconds = encodeMilliseconds;
            if (encoded) {
                self.lastWebcamError = @{};
                ++self.webcamEncodedFrames;
                self.webcamEncodeMillisecondsTotal += encodeMilliseconds;
            }
            self.webcamEncoding = NO;
        }
    });
}

- (void)changeCaptureMode {
    if (self.webcamRequested || self.webcamEnabled) {
        self.captureMode.selectedSegmentIndex = 1;
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:@"captureModeChangeBlocked" details:@{
                @"reason":@"webcamActive", @"requested":@"photo" }];
        });
        [self message:@"Pare a webcam antes de voltar ao modo Foto."];
        return;
    }
    BOOL video = self.captureMode.selectedSegmentIndex == 1;
    self.rawRow.hidden = video;
    self.sizeRow.hidden = video;
    self.videoFormatRow.hidden = !video;
    self.trackingRow.hidden = !video;
    [self updateReframeGuide];
    [self enableControls:NO];
    [self message:video ? @"Configurando vídeo 4:3 a 30 fps…" : @"Voltando ao modo de fotografia…"];
    dispatch_async(self.sessionQueue, ^{ [self configureSessionForVideo:video]; });
}

// sessionQueue only. The same physical camera and manual controls are reused.
- (void)configureSessionForVideo:(BOOL)video {
    if (self.captureBusy || self.comparisonActive || self.videoRecording || self.videoProcessing || self.pendingPhoto || self.closing) {
        if (self.webcamRequested)
            [self failWebcamStartOnSessionQueue:@"captureTopologyBusy" error:nil];
        [self message:@"Aguarde a operação atual antes de trocar o modo."];
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL activeVideo = self.videoModeActive;
            self.captureMode.selectedSegmentIndex = activeVideo ? 1 : 0;
            self.rawRow.hidden = activeVideo; self.sizeRow.hidden = activeVideo;
            self.videoFormatRow.hidden = !activeVideo; self.trackingRow.hidden = !activeVideo;
            [self updateReframeGuide];
        });
        return;
    }
    if (video) {
        AVAuthorizationStatus microphone = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        NSString *usage = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSMicrophoneUsageDescription"];
        BOOL mayRequest = microphone == AVAuthorizationStatusNotDetermined &&
            [usage isKindOfClass:NSString.class] && usage.length > 0;
        [self recordSessionEvent:@"microphoneAuthorization" details:@{@"status":@(microphone), @"mayRequest":@(mayRequest)}];
        if (mayRequest) {
            [self message:@"Aguardando permissão do microfone…"];
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(__unused BOOL granted) {
                dispatch_async(self.sessionQueue, ^{ if (!self.closing) [self configureSessionForVideo:YES]; });
            }];
            return;
        }
    }
    self.configured = NO;
    [self.session stopRunning];
    NSError *error = nil;
    NSError *audioError = nil;
    BOOL audioAdded = NO;
    @try {
        [self.session beginConfiguration];
        if (video) {
            self.videoModeActive = YES;
            self.photoOnlyRequested = NO;
            atomic_store(&M7PhotoOnlyPreferred, false);
            if ([self.session.outputs containsObject:self.photoOutput]) [self.session removeOutput:self.photoOutput];
            if (![self.session.outputs containsObject:self.videoOutput] && [self.session canAddOutput:self.videoOutput])
                [self.session addOutput:self.videoOutput];
            AVAuthorizationStatus microphone = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
            if (microphone == AVAuthorizationStatusAuthorized) {
                AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
                AVCaptureDeviceInput *audioInput = audioDevice ? [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&audioError] : nil;
                if (audioInput && [self.session canAddInput:audioInput] && [self.session canAddOutput:self.audioOutput]) {
                    [self.session addInput:audioInput]; self.audioInput = audioInput;
                    [self.session addOutput:self.audioOutput]; audioAdded = YES;
                }
            }
        } else {
            self.videoModeActive = NO;
            if (self.audioInput && [self.session.inputs containsObject:self.audioInput]) [self.session removeInput:self.audioInput];
            if ([self.session.outputs containsObject:self.audioOutput]) [self.session removeOutput:self.audioOutput];
            self.audioInput = nil;
            if (![self.session.outputs containsObject:self.photoOutput] && [self.session canAddOutput:self.photoOutput])
                [self.session addOutput:self.photoOutput];
            if (!self.photoOnlyRequested && ![self.session.outputs containsObject:self.videoOutput] && [self.session canAddOutput:self.videoOutput])
                [self.session addOutput:self.videoOutput];
            self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        }
        [self.session commitConfiguration];
    } @catch (NSException *exception) {
        @try { [self.session commitConfiguration]; } @catch (__unused NSException *ignored) {}
        error = [self captureExceptionError:exception];
    }
    AVCaptureDeviceType type = self.lens.selectedSegmentIndex ? AVCaptureDeviceTypeBuiltInTelephotoCamera : AVCaptureDeviceTypeBuiltInWideAngleCamera;
    BOOL selected = !error && [self selectDevice:type error:&error];
    self.configured = selected;
    if (selected) [self.session startRunning];
    [self updateVideoOutputDemand];
    AVCaptureConnection *videoConnection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
    if (videoConnection.isVideoOrientationSupported)
        videoConnection.videoOrientation = M7VideoOrientationForMount(self.cameraMount);
    [self recordSessionEvent:@"captureModeConfigured" details:@{@"video":@(video), @"audio":@(audioAdded),
        @"success":@(selected), @"videoFormat":self.videoFormatDiagnostic ?: @{}, @"error":M7ErrorDetails(error),
        @"audioError":M7ErrorDetails(audioError),
        @"session":[self sessionDiagnostic]}];
    if (!selected && video) {
        self.videoModeActive = NO;
        if (self.webcamRequested)
            [self failWebcamStartOnSessionQueue:@"videoModeConfigurationFailed" error:error];
        [self message:[NSString stringWithFormat:@"Falha ao configurar vídeo: %@. Restaurando Foto…",
            error.localizedDescription ?: @"erro desconhecido"]];
        [self configureSessionForVideo:NO];
        return;
    }
    if (selected && video && self.webcamRequested && !self.webcamEnabled)
        [self startWebcamServerForActiveVideo];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.captureMode.selectedSegmentIndex = selected && video ? 1 : 0;
        self.rawRow.hidden = selected && video;
        self.sizeRow.hidden = selected && video;
        self.videoFormatRow.hidden = !(selected && video);
        self.trackingRow.hidden = !(selected && video);
        [self updateReframeGuide];
        [self message:!selected ? error.localizedDescription ?: @"Falha ao configurar o modo." :
            video ? (![self.videoFormatDiagnostic[@"fourThirds"] boolValue] ?
                @"Vídeo pronto em formato alternativo; o relatório registra a geometria." :
                (audioAdded ? @"Vídeo pronto: master 4:3 com áudio." : @"Vídeo pronto sem áudio; permissão ou entrada indisponível.")) :
            @"Fotografia pronta."];
    });
}

- (void)enableControls:(BOOL)ready {
    self.captureAvailable = ready;
    BOOL changingTopology = self.videoRecording || self.videoProcessing;
    self.captureMode.enabled = ready && !changingTopology && !self.webcamRequested && !self.webcamEnabled;
    self.videoFormat.enabled = ready && self.videoModeActive && !changingTopology;
    self.trackingSwitch.enabled = ready && self.videoModeActive && !changingTopology;
    self.webcamSwitch.enabled = ready && !changingTopology;
    self.webcamFormat.enabled = ready && !self.webcamRequested && !self.webcamEnabled;
    self.mountControl.enabled = ready && !changingTopology && !self.webcamRequested && !self.webcamEnabled;
    self.pairButton.enabled = ready && !changingTopology && !self.pairingSubmitting;
    self.lens.enabled = ready && !changingTopology;
    self.exposureMode.enabled = ready; self.focusMode.enabled = ready;
    BOOL manual = ready && self.exposureMode.selectedSegmentIndex == 1 && [self.limits[@"manualExposure"] boolValue];
    self.isoSlider.enabled = manual;
    self.shutterSlider.enabled = manual && [self.limits[@"hasShutterGrid"] boolValue];
    self.focusSlider.enabled = ready && self.focusMode.selectedSegmentIndex == 1 && [self.limits[@"manualFocus"] boolValue];
    self.evStepper.enabled = ready && self.exposureMode.selectedSegmentIndex == 0;
    self.shutterButton.enabled = ready;
    self.rawSwitch.enabled = ready && !self.videoModeActive && [self.lensDiagnostic[@"rawFormats"] count] > 0;
    [self updateModeRows];
    [self updateSizeControl];
}

// Main thread only. Shows only the rows that the selected modes can use.
- (void)updateModeRows {
    NSInteger exposure = self.exposureMode.selectedSegmentIndex;
    [self setRow:self.isoSlider.superview hidden:exposure != 1];
    [self setRow:self.shutterSlider.superview hidden:exposure != 1];
    [self setRow:self.evStepper.superview hidden:exposure != 0];
    [self setRow:self.focusSlider.superview hidden:self.focusMode.selectedSegmentIndex != 1];
    [self setRow:self.thresholdSlider.superview hidden:!self.peakingSwitch.on];
}

- (void)refresh {
    // Nothing on screen to update while the Camera app is inactive.
    if (self.closing || !self.view.window ||
        UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice *d = self.input.device;
        BOOL ready = self.configured && self.session.isRunning && !self.captureBusy &&
            !self.rawCaptureWaiting && !self.videoProcessing;
        BOOL pending = self.pendingPhoto != nil;
        BOOL importing = pending && [self.photosInFlight containsObject:self.pendingPhoto.filename];
        BOOL settled = !self.pendingExposure && !self.pendingFocus;
        double seconds = CMTimeGetSeconds(d.exposureDuration);
        NSString *shutter = seconds > 0 && seconds < 1 ? [NSString stringWithFormat:@"1/%.1f s", 1 / seconds] : [NSString stringWithFormat:@"%.4f s", seconds];
        NSString *readout = d ? [NSString stringWithFormat:@"ISO %.0f · %@ · f/%.1f\nEV %+.2f · Medidor %+.2f EV · Foco %.2f", d.ISO, shutter, d.lensAperture, d.exposureTargetBias, d.exposureTargetOffset, d.lensPosition] : @"Sem câmera ativa";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableControls:ready && !pending];
            self.closeButton.enabled = !self.videoRecording && !self.videoProcessing &&
                !self.captureBusy && !self.rawCaptureWaiting;
            self.shutterButton.enabled = self.videoRecording ? YES : pending ? !importing : ready && settled;
            NSString *title;
            if (self.videoRecording) {
                NSInteger elapsed = MAX(0, (NSInteger)(CACurrentMediaTime() - self.videoStartedAt));
                title = [NSString stringWithFormat:@"■  PARAR · %02ld:%02ld", (long)(elapsed/60), (long)(elapsed%60)];
            } else if (self.rawCaptureWaiting) title = @"Preparando DNG e sensor…";
            else if (self.videoProcessing) title = @"Processando e salvando vídeo…";
            else if (importing) title = @"Salvando no Fotos…";
            else if (pending) title = @"SALVAR FOTO PENDENTE";
            else if (ready && !settled) title = @"Aguardando foco/exposição…";
            else title = self.videoModeActive ? @"●  GRAVAR VÍDEO" : @"●  FOTOGRAFAR";
            // Assigning an identical title still relayouts the button.
            if (![[self.shutterButton titleForState:UIControlStateNormal] isEqualToString:title])
                [self.shutterButton setTitle:title forState:UIControlStateNormal];
            UIColor *fill = self.videoRecording ? UIColor.systemRedColor : UIColor.systemYellowColor;
            if (![self.shutterButton.backgroundColor isEqual:fill]) {
                self.shutterButton.backgroundColor = fill;
                UIColor *ink = self.videoRecording ? UIColor.whiteColor : UIColor.blackColor;
                [self.shutterButton setTitleColor:ink forState:UIControlStateNormal];
                [self.shutterButton setTitleColor:ink forState:UIControlStateDisabled];
            }
            self.shutterButton.alpha = self.shutterButton.enabled ? 1 : .45;
            if (![self.readout.text isEqualToString:readout]) self.readout.text = readout;
        });
    });
}

- (void)recordControlChange:(NSString *)control details:(NSDictionary *)details {
    NSMutableDictionary *value = [details mutableCopy] ?: [NSMutableDictionary new];
    value[@"control"] = control;
    value[@"videoRecording"] = @(self.videoRecording);
    [self recordSessionEvent:@"controlChange" details:value];
    if (self.videoRecording || self.videoProcessing) [self recordVideoStage:@"controlChange" details:value];
}

- (void)changeLens {
    AVCaptureDeviceType type = self.lens.selectedSegmentIndex ? AVCaptureDeviceTypeBuiltInTelephotoCamera : AVCaptureDeviceTypeBuiltInWideAngleCamera;
    [self enableControls:NO]; self.peakingView.image = nil;
    dispatch_async(self.sessionQueue, ^{
        if (self.captureBusy || self.videoRecording || self.videoProcessing || self.closing) return;
        NSError *error = nil;
        if (![self selectDevice:type error:&error]) {
            [self recordControlChange:@"lens" details:@{@"requested":type ?: @"", @"success":@NO,
                @"error":M7ErrorDetails(error)}];
            [self message:error.localizedDescription];
            BOOL tele = [self.input.device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera];
            dispatch_async(dispatch_get_main_queue(), ^{ self.lens.selectedSegmentIndex = tele ? 1 : 0; });
        } else {
            [self recordControlChange:@"lens" details:@{@"requested":type ?: @"", @"success":@YES}];
            [self message:@"Lente alterada; exposição e foco voltaram para AUTO."];
        }
    });
}

- (void)changeExposureMode {
    [self updateModeRows];
    NSInteger mode = self.exposureMode.selectedSegmentIndex;
    if (mode == 1) {
        dispatch_async(self.sessionQueue, ^{
            if (!self.configured || self.captureBusy || self.closing) return;
            AVCaptureDevice *d = self.input.device;
            int index = 0;
            if (!m7_shutter_nearest(CMTimeGetSeconds(d.exposureDuration),
                CMTimeGetSeconds(d.activeFormat.minExposureDuration),
                CMTimeGetSeconds(d.activeFormat.maxExposureDuration), &index)) return;
            float iso = (log(d.ISO) - log(d.activeFormat.minISO)) /
                fmax(1e-9, log(d.activeFormat.maxISO) - log(d.activeFormat.minISO));
            dispatch_async(dispatch_get_main_queue(), ^{
                self.isoSlider.value = iso; self.shutterSlider.value = index;
                if (self.exposureMode.selectedSegmentIndex == 1) [self changeManualExposure];
            });
        });
        return;
    }
    dispatch_async(self.sessionQueue, ^{
        if (!self.configured || self.captureBusy || self.closing) return;
        NSError *error = nil;
        ++self.exposureRevision; self.pendingExposure = NO;
        BOOL ok = mode == 0 ? [self.controls enableAutoExposure:&error] : [self.controls lockExposure:&error];
        [self recordControlChange:@"exposureMode" details:@{@"mode":@(mode), @"success":@(ok),
            @"error":M7ErrorDetails(error)}];
        if (!ok) [self message:error.localizedDescription];
    });
}

- (void)changeManualExposure {
    double iso = m7_iso_from_slider(self.isoSlider.value, [self.limits[@"minISO"] doubleValue], [self.limits[@"maxISO"] doubleValue]);
    int index = (int)lroundf(self.shutterSlider.value); self.shutterSlider.value = index;
    dispatch_async(self.sessionQueue, ^{
        if (!self.configured || self.captureBusy || self.closing) return;
        NSError *error = nil;
        NSUInteger revision = ++self.exposureRevision;
        self.pendingExposure = YES;
        [self recordControlChange:@"manualExposureRequested" details:@{@"ISO":@(iso), @"shutterIndex":@(index),
            @"seconds":@(m7_shutter_seconds(index)), @"revision":@(revision)}];
        __weak typeof(self) weakSelf = self;
        BOOL ok = [self.controls setISO:(float)iso shutterIndex:index completion:^(__unused CMTime time) {
            typeof(self) owner = weakSelf; if (!owner) return;
            dispatch_async(owner.sessionQueue, ^{
                if (owner.exposureRevision == revision) owner.pendingExposure = NO;
                [owner recordControlChange:@"manualExposureApplied" details:@{@"revision":@(revision),
                    @"ISO":@(owner.input.device.ISO), @"seconds":@(CMTimeGetSeconds(owner.input.device.exposureDuration))}];
            });
        } error:&error];
        if (!ok) {
            self.pendingExposure = NO;
            [self recordControlChange:@"manualExposureFailed" details:@{@"revision":@(revision), @"error":M7ErrorDetails(error)}];
            [self message:error.localizedDescription];
        }
    });
}

- (void)changeFocusMode {
    [self updateModeRows];
    NSInteger mode = self.focusMode.selectedSegmentIndex;
    if (mode == 1) {
        dispatch_async(self.sessionQueue, ^{
            float position = self.input.device.lensPosition;
            dispatch_async(dispatch_get_main_queue(), ^{
                self.focusSlider.value = position;
                if (self.focusMode.selectedSegmentIndex == 1) [self changeManualFocus];
            });
        });
        return;
    }
    dispatch_async(self.sessionQueue, ^{
        if (!self.configured || self.captureBusy || self.closing) return;
        NSError *error = nil;
        ++self.focusRevision; self.pendingFocus = NO;
        BOOL ok = mode == 0 ? [self.controls enableAutoFocus:&error] : [self.controls lockFocus:&error];
        [self recordControlChange:@"focusMode" details:@{@"mode":@(mode), @"success":@(ok),
            @"error":M7ErrorDetails(error)}];
        if (!ok) [self message:error.localizedDescription];
    });
}

- (void)changeManualFocus {
    CFTimeInterval now = CACurrentMediaTime();
    if (self.focusSlider.tracking && now - self.lastFocusRequest < .08) return;
    self.lastFocusRequest = now;
    float position = self.focusSlider.value;
    dispatch_async(self.sessionQueue, ^{
        if (!self.configured || self.captureBusy || self.closing) return;
        NSError *error = nil;
        NSUInteger revision = ++self.focusRevision; self.pendingFocus = YES;
        [self recordControlChange:@"manualFocusRequested" details:@{@"position":@(position), @"revision":@(revision)}];
        __weak typeof(self) weakSelf = self;
        BOOL ok = [self.controls setManualFocus:position completion:^(__unused CMTime time) {
            typeof(self) owner = weakSelf; if (!owner) return;
            dispatch_async(owner.sessionQueue, ^{
                if (owner.focusRevision == revision) owner.pendingFocus = NO;
                [owner recordControlChange:@"manualFocusApplied" details:@{@"position":@(owner.input.device.lensPosition),
                    @"revision":@(revision)}];
            });
        } error:&error];
        if (!ok) {
            self.pendingFocus = NO;
            [self recordControlChange:@"manualFocusFailed" details:@{@"revision":@(revision), @"error":M7ErrorDetails(error)}];
            [self message:error.localizedDescription];
        }
    });
}

- (void)changeEV {
    NSInteger thirds = (NSInteger)self.evStepper.value;
    dispatch_async(self.sessionQueue, ^{
        if (self.captureBusy || self.closing) return;
        NSError *error = nil;
        NSUInteger revision = ++self.exposureRevision; self.pendingExposure = YES;
        [self recordControlChange:@"evRequested" details:@{@"thirds":@(thirds), @"revision":@(revision)}];
        __weak typeof(self) weakSelf = self;
        BOOL ok = [self.controls setExposureBiasThirds:thirds completion:^(__unused CMTime time) {
            typeof(self) owner = weakSelf; if (!owner) return;
            dispatch_async(owner.sessionQueue, ^{
                if (owner.exposureRevision == revision) owner.pendingExposure = NO;
                [owner recordControlChange:@"evApplied" details:@{@"bias":@(owner.input.device.exposureTargetBias),
                    @"revision":@(revision)}];
            });
        } error:&error];
        if (!ok) {
            self.pendingExposure = NO;
            [self recordControlChange:@"evFailed" details:@{@"revision":@(revision), @"error":M7ErrorDetails(error)}];
            [self message:error.localizedDescription ?: @"Câmera ainda não está pronta."];
        }
    });
}

- (void)changePeaking {
    [self updateModeRows];
    self.peakingEnabled = self.peakingSwitch.on;
    self.peakingThreshold = self.thresholdSlider.value;
    if (!self.peakingEnabled) self.peakingView.image = nil;
    BOOL enabled = self.peakingEnabled;
    double threshold = self.peakingThreshold;
    dispatch_async(self.sessionQueue, ^{
        [self updateVideoOutputDemand];
        [self recordControlChange:@"peaking" details:@{@"enabled":@(enabled), @"threshold":@(threshold)}];
    });
}

// sessionQueue only. The in-memory report remains available when Camera cannot
// write Documents/Application Support; a best-effort JSON mirrors photo logs.
- (void)recordVideoStage:(NSString *)stage details:(NSDictionary *)details {
    if (!self.videoTrace) self.videoTrace = [NSMutableDictionary new];
    NSMutableArray *events = self.videoTrace[@"events"];
    if (!events) { events = [NSMutableArray new]; self.videoTrace[@"events"] = events; }
    [events addObject:@{@"stage":stage, @"time":@(NSDate.date.timeIntervalSince1970),
        @"details":M7JSONSnapshot(details ?: @{})}];
    if (events.count > 80) [events removeObjectAtIndex:0];
    self.videoTrace[@"version"] = @"0.7.7";
    self.videoTrace[@"controllerID"] = self.controllerID;
    self.videoTrace[@"sessionID"] = self.sessionID;
    self.videoTrace[@"processID"] = @(getpid());
    self.videoTrace[@"updatedAt"] = @(NSDate.date.timeIntervalSince1970);
    NSError *writeError = nil;
    [self.storage writeJSON:self.videoTrace filename:@"ultimo-video.json" error:&writeError];
    if (writeError) self.videoTrace[@"diagnosticWriteError"] = writeError.localizedDescription;
}

- (NSURL *)videoWorkingDirectoryWithError:(NSError **)error {
    NSString *temporary = NSTemporaryDirectory();
    if (!temporary.length) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.Video" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"O processo Câmera não forneceu pasta temporária."}];
        return nil;
    }
    NSURL *directory = [[NSURL fileURLWithPath:temporary isDirectory:YES]
        URLByAppendingPathComponent:@"Manual7-Video" isDirectory:YES];
    if (![NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES
        attributes:nil error:error]) return nil;
    NSURL *probe = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@".probe-%@", NSUUID.UUID.UUIDString]];
    NSData *data = [@"M7" dataUsingEncoding:NSUTF8StringEncoding];
    if (![data writeToURL:probe options:NSDataWritingAtomic error:error]) return nil;
    [NSFileManager.defaultManager removeItemAtURL:probe error:nil];
    return directory;
}

- (void)beginVideoBackgroundTask {
    if (self.videoBackgroundTask != UIBackgroundTaskInvalid) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.videoBackgroundTask != UIBackgroundTaskInvalid) return;
        self.videoBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Manual7 Video"
            expirationHandler:^{
                dispatch_async(self.sessionQueue, ^{
                    [self recordVideoStage:@"backgroundTimeExpired" details:@{}];
                    [self endVideoBackgroundTask];
                });
            }];
    });
}

- (void)endVideoBackgroundTask {
    UIBackgroundTaskIdentifier identifier = self.videoBackgroundTask;
    if (identifier == UIBackgroundTaskInvalid) return;
    self.videoBackgroundTask = UIBackgroundTaskInvalid;
    dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication endBackgroundTask:identifier]; });
}

- (void)startVideoRecordingWithOutputMode:(NSInteger)outputMode {
    if (!self.videoModeActive || !self.configured || !self.session.isRunning || self.captureBusy ||
        self.videoProcessing || self.pendingExposure || self.pendingFocus || self.closing) {
        [self message:@"Vídeo indisponível; aguarde a configuração, foco e exposição."]; return;
    }
    NSError *error = nil;
    NSURL *directory = [self videoWorkingDirectoryWithError:&error];
    NSString *identifier = NSUUID.UUID.UUIDString;
    self.videoTrace = [@{@"id":identifier, @"outputMode":@(outputMode),
        @"requestedOutputs":outputMode == 0 ? @[@"horizontal16x9"] :
            outputMode == 1 ? @[@"vertical9x16"] : @[@"horizontal16x9", @"vertical9x16"],
        @"startedAt":@(NSDate.date.timeIntervalSince1970),
        @"trackingRequested":@(self.trackingEnabled)} mutableCopy];
    [self recordVideoStage:@"requested" details:@{@"outputMode":@(outputMode),
        @"session":[self sessionDiagnostic], @"videoFormat":self.videoFormatDiagnostic ?: @{},
        @"microphoneAuthorization":@([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio]),
        @"tracking":@{ @"enabled":@(self.trackingEnabled), @"detector":@"humanUpperBodyWithFaceFallback",
            @"analysisHz":@5 }}];
    if (!directory) {
        [self recordVideoStage:@"temporaryDirectoryFailed" details:M7ErrorDetails(error)];
        [self message:error.localizedDescription ?: @"Pasta temporária de vídeo indisponível."]; return;
    }
    NSNumber *availableBytes = nil;
    [directory getResourceValue:&availableBytes forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
    [self recordVideoStage:@"temporaryDirectoryReady" details:@{@"path":directory.path ?: @"",
        @"availableBytes":availableBytes ?: @0}];
    NSURL *master = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"M7-master-%@.mov", identifier]];
    M7VideoRecorder *recorder = [[M7VideoRecorder alloc] initWithOutputURL:master];
    dispatch_sync(self.videoQueue, ^{ self.videoRecorder = recorder; self.lastTrackingTime = 0; });
    dispatch_sync(self.trackingQueue, ^{
        [self.subjectTracker reset]; self.lastTrackingErrorLogTime = 0;
    });
    self.videoTrackingPoints = @[];
    self.trackingPending = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.trackingCenter = CGPointMake(.5, .5); self.trackingDetected = NO;
        [self updateReframeGuide];
    });
    self.videoMasterURL = master;
    self.activeVideoOutputMode = outputMode;
    self.videoSavedCount = 0;
    self.videoFailedCount = 0;
    self.videoExportFailureCount = 0;
    self.videoStartedAt = CACurrentMediaTime();
    self.videoRecording = YES;
    self.videoProcessing = NO;
    [self beginVideoBackgroundTask];
    [self recordVideoStage:@"waitingForFirstFrame" details:@{@"masterPath":master.path ?: @"",
        @"trackingEnabled":@(self.trackingEnabled)}];
    [self message:self.trackingEnabled ? @"Gravando master 4:3 com rastreamento…"
        : @"Gravando master 4:3… controles manuais permanecem ativos."];
}

- (void)stopVideoRecordingReason:(NSString *)reason error:(NSError *)initialError {
    if (!self.videoRecording) return;
    self.videoRecording = NO;
    self.videoProcessing = YES;
    [self recordVideoStage:@"stopRequested" details:@{@"reason":reason ?: @"user",
        @"initialError":M7ErrorDetails(initialError)}];
    [self message:@"Finalizando o master…"];
    M7VideoRecorder *recorder = self.videoRecorder;
    dispatch_async(self.videoQueue, ^{
        [recorder finishWithCompletion:^(NSURL *url, NSDictionary *summary, NSError *finishError) {
            dispatch_async(self.sessionQueue, ^{
                self.videoRecorder = nil;
                NSError *error = initialError ?: finishError;
                __block NSArray<NSDictionary *> *trackingPoints = @[];
                __block NSDictionary *trackingSummary = @{};
                if ([self.videoTrace[@"trackingRequested"] boolValue]) {
                    dispatch_sync(self.trackingQueue, ^{
                        trackingPoints = [self.subjectTracker trackingPoints];
                        trackingSummary = [self.subjectTracker snapshot];
                    });
                    self.videoTrackingPoints = trackingPoints;
                    self.videoTrace[@"tracking"] = M7TrackingReport(trackingPoints, trackingSummary);
                    [self recordVideoStage:@"trackingFinished" details:@{ @"summary":trackingSummary,
                        @"totalPoints":@(trackingPoints.count) }];
                } else self.videoTrackingPoints = @[];
                [self recordVideoStage:@"masterFinished" details:@{@"recorder":summary ?: @{},
                    @"file":M7VideoFileDetails(url), @"error":M7ErrorDetails(error)}];
                if (error) {
                    self.videoProcessing = NO;
                    ++self.videoFailedCount;
                    [NSFileManager.defaultManager removeItemAtURL:url error:nil];
                    [self endVideoBackgroundTask];
                    [self message:[NSString stringWithFormat:@"Falha na gravação: %@", error.localizedDescription]];
                    return;
                }
                self.videoMasterURL = url;
                self.videoFramesToExport = self.activeVideoOutputMode == 0 ? @[@(M7VideoFrameHorizontal)] :
                    self.activeVideoOutputMode == 1 ? @[@(M7VideoFrameVertical)] :
                    @[@(M7VideoFrameHorizontal), @(M7VideoFrameVertical)];
                self.videoExportIndex = 0; self.videoSavedCount = 0; self.videoFailedCount = 0;
                [self processNextVideoFrame];
            });
        }];
    });
}

- (void)saveVideoURLToPhotos:(NSURL *)url label:(NSString *)label mayRequest:(BOOL)mayRequest
    completion:(void (^)(BOOL success, NSString *assetID, NSError *error))completion {
    PHAuthorizationStatus add = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
    PHAuthorizationStatus read = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
    NSString *usage = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryAddUsageDescription"];
    BOOL authorized = add == PHAuthorizationStatusAuthorized || read == PHAuthorizationStatusAuthorized || read == PHAuthorizationStatusLimited;
    [self recordVideoStage:@"photosAuthorization" details:@{@"label":label, @"addOnly":@(add),
        @"readWrite":@(read), @"hasUsageDescription":@([usage isKindOfClass:NSString.class] && usage.length > 0)}];
    if (!authorized && add == PHAuthorizationStatusNotDetermined && mayRequest && usage.length) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(__unused PHAuthorizationStatus status) {
            dispatch_async(self.sessionQueue, ^{ [self saveVideoURLToPhotos:url label:label mayRequest:NO completion:completion]; });
        }];
        return;
    }
    if (!authorized) {
        completion(NO, @"", [NSError errorWithDomain:@"Manual7.VideoPhotos" code:1
            userInfo:@{NSLocalizedDescriptionKey:@"O Fotos não autorizou a inclusão do vídeo."}]);
        return;
    }
    __block NSString *assetID = nil;
    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
        PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
        options.originalFilename = url.lastPathComponent;
        options.shouldMoveFile = NO;
        [request addResourceWithType:PHAssetResourceTypeVideo fileURL:url options:options];
        assetID = request.placeholderForCreatedAsset.localIdentifier;
    } completionHandler:^(BOOL success, NSError *error) {
        dispatch_async(self.sessionQueue, ^{
            BOOL confirmed = success && assetID.length > 0;
            NSError *resultError = confirmed ? nil : error ?: [NSError errorWithDomain:@"Manual7.VideoPhotos" code:2
                userInfo:@{NSLocalizedDescriptionKey:@"O Fotos não confirmou um identificador para o vídeo."}];
            completion(confirmed, assetID ?: @"", resultError);
        });
    }];
}

- (void)processNextVideoFrame {
    if (self.videoExportIndex >= self.videoFramesToExport.count) {
        if (self.videoExportFailureCount && [NSFileManager.defaultManager fileExistsAtPath:self.videoMasterURL.path]) {
            [self.pendingVideos addObject:@{@"url":self.videoMasterURL, @"label":@"master4x3"}];
            [self recordVideoStage:@"masterRetainedAfterExportFailure" details:M7VideoFileDetails(self.videoMasterURL)];
        } else [NSFileManager.defaultManager removeItemAtURL:self.videoMasterURL error:nil];
        [self recordVideoStage:@"completed" details:@{@"saved":@(self.videoSavedCount),
            @"failed":@(self.videoFailedCount), @"pending":@(self.pendingVideos.count)}];
        self.videoProcessing = NO;
        [self endVideoBackgroundTask];
        NSString *message = self.videoSavedCount ? [NSString stringWithFormat:@"%lu vídeo(s) salvo(s) no Fotos%@.",
            (unsigned long)self.videoSavedCount, self.videoFailedCount ? @"; houve falhas registradas" : @""] :
            @"Nenhum vídeo foi salvo; consulte Exportar → Ver diagnóstico.";
        [self message:message];
        return;
    }
    M7VideoFrame frame = (M7VideoFrame)self.videoFramesToExport[self.videoExportIndex].integerValue;
    NSString *label = frame == M7VideoFrameVertical ? @"vertical9x16" : @"horizontal16x9";
    NSURL *directory = self.videoMasterURL.URLByDeletingLastPathComponent;
    NSURL *output = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"M7-%@-%@.mp4", label, self.videoTrace[@"id"] ?: NSUUID.UUID.UUIDString]];
    [self recordVideoStage:@"exportStarted" details:@{@"label":label, @"source":M7VideoFileDetails(self.videoMasterURL),
        @"outputPath":output.path ?: @"", @"trackingPoints":@(self.videoTrackingPoints.count)}];
    [self message:[NSString stringWithFormat:@"Gerando %@…", label]];
    M7ExportTrackedVideoFrame(self.videoMasterURL, output, frame, self.videoTrackingPoints ?: @[],
        ^(NSDictionary *details, NSError *error) {
        dispatch_async(self.sessionQueue, ^{
            [self recordVideoStage:@"exportFinished" details:@{@"label":label, @"result":details ?: @{},
                @"error":M7ErrorDetails(error)}];
            if (error) {
                ++self.videoFailedCount; ++self.videoExportFailureCount; ++self.videoExportIndex;
                [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                [self processNextVideoFrame]; return;
            }
            [self saveVideoURLToPhotos:output label:label mayRequest:YES completion:^(BOOL success, NSString *assetID, NSError *saveError) {
                [self recordVideoStage:@"photosResult" details:@{@"label":label, @"success":@(success),
                    @"assetID":assetID ?: @"", @"file":M7VideoFileDetails(output), @"error":M7ErrorDetails(saveError)}];
                if (success) {
                    ++self.videoSavedCount;
                    [NSFileManager.defaultManager removeItemAtURL:output error:nil];
                } else {
                    ++self.videoFailedCount;
                    [self.pendingVideos addObject:@{@"url":output, @"label":label}];
                }
                ++self.videoExportIndex;
                [self processNextVideoFrame];
            }];
        });
    });
}

- (void)retryPendingVideoItems:(NSArray<NSDictionary *> *)items index:(NSUInteger)index saved:(NSUInteger)saved {
    if (index >= items.count) {
        self.videoProcessing = NO;
        [self endVideoBackgroundTask];
        [self message:[NSString stringWithFormat:@"%lu vídeo(s) recuperado(s); %lu ainda pendente(s).",
            (unsigned long)saved, (unsigned long)self.pendingVideos.count]];
        return;
    }
    NSDictionary *item = items[index];
    NSURL *url = item[@"url"];
    NSString *label = item[@"label"] ?: @"video";
    if (!url || ![NSFileManager.defaultManager fileExistsAtPath:url.path]) {
        [self.pendingVideos removeObject:item];
        [self recordVideoStage:@"pendingVideoMissing" details:@{@"label":label, @"path":url.path ?: @""}];
        [self retryPendingVideoItems:items index:index+1 saved:saved];
        return;
    }
    [self saveVideoURLToPhotos:url label:label mayRequest:YES completion:^(BOOL success, NSString *assetID, NSError *error) {
        [self recordVideoStage:@"pendingVideoRetry" details:@{@"label":label, @"success":@(success),
            @"assetID":assetID ?: @"", @"error":M7ErrorDetails(error)}];
        if (success) {
            [self.pendingVideos removeObject:item];
            [NSFileManager.defaultManager removeItemAtURL:url error:nil];
        }
        [self retryPendingVideoItems:items index:index+1 saved:saved + (success ? 1 : 0)];
    }];
}

- (void)retryPendingVideos {
    if (self.videoRecording || self.videoProcessing || !self.pendingVideos.count) return;
    self.videoProcessing = YES;
    [self beginVideoBackgroundTask];
    [self retryPendingVideoItems:[self.pendingVideos copy] index:0 saved:0];
}

- (void)shutterTapped {
    [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
    [self capture];
}

- (void)capture {
    NSInteger mode = self.videoFormat.selectedSegmentIndex;
    if (self.videoModeActive) {
        dispatch_async(self.sessionQueue, ^{
            if (self.videoRecording) [self stopVideoRecordingReason:@"user" error:nil];
            else [self startVideoRecordingWithOutputMode:mode];
        });
        return;
    }
    BOOL raw = self.rawSwitch.on;
    NSUInteger longEdge = raw ? 0 : self.jpegLongEdge;
    dispatch_async(self.sessionQueue, ^{
        if (self.comparisonActive) { [self message:@"Teste RAW em andamento; aguarde o relatório."]; return; }
        [self captureRAW:raw longEdge:longEdge];
    });
}

// sessionQueue only. Give RAW resource preparation and sensor convergence a
// bounded window. A timeout still submits because Apple's preparation hint is
// optional and continuous autofocus may remain active in a moving scene.
- (void)captureRAW:(BOOL)raw longEdge:(NSUInteger)longEdge {
    if (!raw) { [self submitCaptureRAW:NO longEdge:longEdge]; return; }
    if (self.rawCaptureWaiting) {
        [self message:@"O disparo RAW anterior ainda está sendo preparado."];
        return;
    }
    self.rawCaptureWaiting = YES;
    NSUInteger generation = ++self.rawWaitGeneration;
    [self waitForRAWReadinessAndCaptureLongEdge:longEdge generation:generation
        startedAt:CACurrentMediaTime() first:YES];
}

- (void)waitForRAWReadinessAndCaptureLongEdge:(NSUInteger)longEdge
    generation:(NSUInteger)generation startedAt:(CFTimeInterval)startedAt first:(BOOL)first {
    if (generation != self.rawWaitGeneration || self.closing) {
        self.rawCaptureWaiting = NO;
        [self completeComparison:@"cancelledWhilePreparing"];
        return;
    }
    AVCaptureDevice *device = self.input.device;
    CFTimeInterval elapsed = CACurrentMediaTime() - startedAt;
    BOOL sensorAdjusting = device.isAdjustingExposure || device.isAdjustingFocus ||
        self.pendingExposure || self.pendingFocus;
    BOOL waiting = self.rawPreparationPending || sensorAdjusting;
    if (waiting && elapsed < 3.0) {
        if (first) {
            [self recordSessionEvent:@"rawCaptureWaiting" details:@{
                @"preparationPending":@(self.rawPreparationPending),
                @"adjustingExposure":@(device.isAdjustingExposure),
                @"adjustingFocus":@(device.isAdjustingFocus),
                @"pendingExposure":@(self.pendingExposure), @"pendingFocus":@(self.pendingFocus) }];
            [self message:@"Preparando DNG e aguardando o sensor…"];
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), self.sessionQueue, ^{
            [self waitForRAWReadinessAndCaptureLongEdge:longEdge generation:generation
                startedAt:startedAt first:NO];
        });
        return;
    }
    self.rawCaptureWaiting = NO;
    [self recordSessionEvent:@"rawCaptureReady" details:@{
        @"waitMilliseconds":@(llround(elapsed * 1000.0)), @"timedOut":@(waiting),
        @"preparationPending":@(self.rawPreparationPending), @"prepared":@(self.rawPrepared),
        @"adjustingExposure":@(device.isAdjustingExposure), @"adjustingFocus":@(device.isAdjustingFocus),
        @"preparation":self.rawPreparationReport ?: @{} }];
    [self submitCaptureRAW:YES longEdge:longEdge];
}

// sessionQueue only. Test configuration and submission run in one operation.
- (void)submitCaptureRAW:(BOOL)raw longEdge:(NSUInteger)longEdge {

        if (self.pendingPhoto) { [self savePhotoToPhotos:self.pendingPhoto]; return; }
        if (!self.configured || !self.session.isRunning || self.captureBusy ||
            self.pendingExposure || self.pendingFocus || self.closing) {
            [self recordCaptureStage:@"captureBlocked" details:[self sessionDiagnostic]];
            [self message:@"Disparo indisponível. Abra Exportar → Ver diagnóstico."];
            [self completeComparison:@"captureBlocked"];
            return;
        }
        self.captureID = 0;
        self.captureTrace = [NSMutableDictionary new];
        if (self.comparisonActive) self.captureTrace[@"comparisonID"] = self.comparisonReport[@"id"];
        NSDictionary *rawCompatibility = raw ? [self.controls rawCompatibilityForOutput:self.photoOutput] : @{};
        [self recordCaptureStage:@"requested" details:@{@"raw":@(raw), @"jpegLongEdge":@(longEdge),
            @"device":self.input.device.deviceType ?: @"", @"highResolutionEnabled":@(self.photoOutput.isHighResolutionCaptureEnabled),
            @"rawCompatibility":rawCompatibility, @"rawPreparation":self.rawPreparationReport ?: @{},
            @"session":[self sessionDiagnostic]}];
        NSError *error = nil;
        // A denied local backup must never prevent AVFoundation/PhotoKit.
        if (![self.storage prepare:&error]) [self recordCaptureStage:@"localBackupUnavailable"
            details:@{@"message":error.localizedDescription ?: @"Pasta indisponível"}];
        error = nil;
        @try {
            if (self.photoOnlyRequested && ![self isPhotoOnlySession])
                [NSException raise:NSInternalInconsistencyException format:@"O modo sem peaking foi solicitado, mas as saídas não correspondem. Disparo bloqueado; consulte o diagnóstico."];
            if (![self respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)] ||
                ![self respondsToSelector:@selector(captureOutput:didFinishCaptureForResolvedSettings:error:)]) {
                [NSException raise:NSInvalidArgumentException format:@"Callbacks Objective-C de captura indisponíveis."];
            }
            AVCaptureConnection *connection = [self.photoOutput connectionWithMediaType:AVMediaTypeVideo];
            if (!connection || !connection.isEnabled || !connection.isActive)
                [NSException raise:NSInvalidArgumentException format:@"A conexão de fotografia ainda não está ativa."];
            if (raw && (fabs(self.input.device.videoZoomFactor - 1.0) > .0001 ||
                        fabs(connection.videoScaleAndCropFactor - 1.0) > .0001))
                [NSException raise:NSInvalidArgumentException format:@"DNG exige zoom e recorte digital em 1×."];
            if (!raw && (![self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG] ||
                         !self.photoOutput.isHighResolutionCaptureEnabled))
                [NSException raise:NSInvalidArgumentException format:@"JPEG na resolução original indisponível nesta sessão."];
            NSDictionary *settingsDiagnostic = nil;
            AVCapturePhotoSettings *settings = raw ? [self.controls rawSettingsForOutput:self.photoOutput
                includeProcessedJPEG:self.comparisonActive diagnostic:&settingsDiagnostic error:&error] :
                [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}];
            if (!settings) { [self finishCaptureWithError:error]; return; }
            settings.photoQualityPrioritization = AVCapturePhotoQualityPrioritizationSpeed;
            if (![self.photoOutput.supportedFlashModes containsObject:@(AVCaptureFlashModeOff)])
                [NSException raise:NSInvalidArgumentException format:@"Flash desligado indisponível nesta configuração."];
            settings.flashMode = AVCaptureFlashModeOff;
            // iOS 15 API. Smaller JPEG sizes are derived after full-size capture.
            settings.highResolutionPhotoEnabled = !raw;
            self.captureBusy = YES; self.captureRAW = raw; self.captureID = settings.uniqueID;
            self.captureLongEdge = longEdge;
            self.captureResult = [[M7CaptureResult alloc] initWithID:settings.uniqueID wantsRAW:raw];
            self.captureData = nil; self.captureError = nil; self.captureMetadata = nil;
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = NO; [self enableControls:NO]; });
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            BOOL autoStillImageStabilization = settings.isAutoStillImageStabilizationEnabled;
#pragma clang diagnostic pop
            [self recordCaptureStage:@"submit" details:@{@"id":@(settings.uniqueID),
                @"rawFormat":@(settings.rawPhotoPixelFormatType), @"processedFormat":settings.format ?: @{},
                @"rawFourCC":settings.rawPhotoPixelFormatType ? M7RAWFourCC(settings.rawPhotoPixelFormatType) : @"",
                @"rawFileType":settings.rawFileType ?: @"", @"processedFileType":settings.processedFileType ?: @"",
                @"autoStillImageStabilization":@(autoStillImageStabilization),
                @"qualityPrioritization":@(settings.photoQualityPrioritization),
                @"settingsDiagnostic":settingsDiagnostic ?: @{},
                @"settingsClass":NSStringFromClass(settings.class), @"highResolution":@(settings.isHighResolutionPhotoEnabled), @"session":[self sessionDiagnostic]}];
            if (self.comparisonActive) self.comparisonReport[@"captureID"] = @(settings.uniqueID);
            [self message:@"Capturando…"];
            if (self.photoOnlyRequested && ![self isPhotoOnlySession])
                [NSException raise:NSInternalInconsistencyException format:@"As saídas mudaram antes do disparo. Captura bloqueada."];
            [self.photoOutput capturePhotoWithSettings:settings delegate:self];
            int64_t identifier = settings.uniqueID;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), self.sessionQueue, ^{
                typeof(self) owner = weakSelf;
                if (!owner || !owner.captureBusy || owner.captureID != identifier) return;
                owner.captureID = 0; owner.configured = NO;
                [owner finishCaptureWithError:[NSError errorWithDomain:@"Manual7.Timeout" code:1 userInfo:@{
                    NSLocalizedDescriptionKey:@"A captura não terminou em 30 s. Feche e reabra M7."}]];
                [owner.session stopRunning];
            });
        } @catch (NSException *exception) {
            self.captureID = 0;
            [self finishCaptureWithError:[self captureExceptionError:exception]];
        }
}

- (void)captureOutput:(__unused AVCapturePhotoOutput *)output willBeginCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings {
    dispatch_async(self.sessionQueue, ^{
        if (settings.uniqueID != self.captureID) return;
        CMVideoDimensions dimensions = self.captureRAW ? settings.rawPhotoDimensions : settings.photoDimensions;
        [self recordCaptureStage:@"willBegin" details:@{@"width":@(dimensions.width), @"height":@(dimensions.height), @"expectedPhotoCount":@(settings.expectedPhotoCount)}];
    });
}

- (void)captureOutput:(__unused AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    // AVFoundation invokes callbacks on one queue. Enqueue in that order; keep
    // the immutable AVCapturePhoto alive until its representation is copied.
    dispatch_async(self.sessionQueue, ^{
        if (photo.resolvedSettings.uniqueID != self.captureID) return;
        @autoreleasepool {
            BOOL raw = photo.isRawPhoto;
            BOOL representationAttempted = NO;
            NSData *data = nil;
            NSDictionary *metadata = nil;
            NSError *processingError = error;
            @try {
                CVPixelBufferRef pixel = photo.pixelBuffer;
                [self recordCaptureStage:@"processing" details:@{@"raw":@(raw),
                    @"id":@(photo.resolvedSettings.uniqueID), @"hasPixelBuffer":@(pixel != NULL),
                    @"pixelWidth":@(pixel ? CVPixelBufferGetWidth(pixel) : 0),
                    @"pixelHeight":@(pixel ? CVPixelBufferGetHeight(pixel) : 0),
                    @"pixelFormat":@(pixel ? CVPixelBufferGetPixelFormatType(pixel) : 0),
                    @"errorDetails":M7ErrorDetails(error)}];
                // A callback failure is not a failed call to fileDataRepresentation.
                if (!error) {
                    representationAttempted = YES;
                    data = photo.fileDataRepresentation;
                    metadata = photo.metadata;
                    if (!data.length) processingError = [NSError errorWithDomain:@"Manual7.Capture" code:2
                        userInfo:@{NSLocalizedDescriptionKey:@"Falha ao gerar o arquivo a partir da foto recebida."}];
                }
            } @catch (NSException *exception) {
                processingError = [self captureExceptionError:exception];
            }
            [self recordCaptureStage:representationAttempted ? @"representation" : @"representationSkipped"
                details:@{@"raw":@(raw), @"attempted":@(representationAttempted), @"bytes":@(data.length),
                    @"errorDetails":M7ErrorDetails(processingError)}];
            // RAW and JPEG callbacks may arrive in either order. The companion is
            // diagnostic only; it must not overwrite RAW bytes or mask a RAW error.
            if ([self.captureResult receiveID:photo.resolvedSettings.uniqueID raw:raw data:data metadata:metadata error:processingError]) {
                self.captureError = self.captureResult.processingError;
                self.captureData = self.captureResult.data;
                self.captureMetadata = self.captureResult.metadata;
            }
        }
    });
}

- (void)captureOutput:(__unused AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error {
    dispatch_async(self.sessionQueue, ^{
        if (settings.uniqueID != self.captureID) return;
        @autoreleasepool {
            [self recordCaptureStage:@"captureFinished" details:@{@"errorDetails":M7ErrorDetails(error),
                @"processingError":M7ErrorDetails(self.captureError), @"bytes":@(self.captureData.length)}];
            NSError *failure = [self.captureResult finishWithError:error];
            if (failure || !self.captureData.length) {
                [self finishCaptureWithError:failure ?: [NSError errorWithDomain:@"Manual7.Capture" code:3
                    userInfo:@{NSLocalizedDescriptionKey:@"A captura terminou sem imagem."}]];
                return;
            }
            M7Photo *photo = [M7Photo new];
            photo.filename = [NSString stringWithFormat:@"M7-%@.%@", NSUUID.UUID.UUIDString, self.captureRAW ? @"dng" : @"jpg"];
            photo.captureID = settings.uniqueID;
            photo.data = self.captureData;
            self.pendingPhoto = photo;
            // Keep an owner independent of captureData before clearing callback state.
            self.captureBusy = NO; self.captureData = nil; self.captureMetadata = nil; self.captureResult = nil;
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = YES; });
            NSError *resizeError = nil;
            if (!self.captureRAW && self.captureLongEdge) {
                @try {
                    NSData *scaled = M7JPEGForLongEdge(photo.data, self.captureLongEdge, &resizeError);
                    if (scaled.length) photo.data = scaled;
                } @catch (NSException *exception) { resizeError = [self captureExceptionError:exception]; }
            }
            [self recordCaptureStage:@"encodedPhotoReady" details:@{@"filename":photo.filename,
                @"bytes":@(photo.data.length), @"resizeError":resizeError.localizedDescription ?: @""}];
            // This copy is useful for Exportar, but never a prerequisite for Photos.
            @try {
                NSURL *directory = self.outputDirectory;
                if (directory) {
                    NSURL *file = [directory URLByAppendingPathComponent:photo.filename];
                    NSError *writeError = nil;
                    if ([photo.data writeToURL:file options:NSDataWritingAtomic error:&writeError]) {
                        photo.file = file;
                        [self recordCaptureStage:@"localBackupSaved" details:@{@"filename":photo.filename}];
                    } else [self recordCaptureStage:@"localBackupFailed" details:@{@"domain":writeError.domain ?: @"",
                        @"code":@(writeError.code), @"message":writeError.localizedDescription ?: @"Falha ao gravar"}];
                }
                NSDictionary *properties = M7ImageProperties(photo.data);
                [self recordCaptureStage:@"dimensions" details:@{@"width":properties[@"PixelWidth"] ?: @0,
                    @"height":properties[@"PixelHeight"] ?: @0}];
                if (photo.file && [NSJSONSerialization isValidJSONObject:properties]) {
                    NSData *metadata = [NSJSONSerialization dataWithJSONObject:properties options:NSJSONWritingPrettyPrinted error:nil];
                    [metadata writeToURL:[[photo.file URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"] atomically:YES];
                }
            } @catch (NSException *exception) {
                [self recordCaptureStage:@"localBackupException" details:@{@"message":exception.reason ?: exception.name}];
            }
            [self savePhotoToPhotos:photo];
        }
    });
}

// sessionQueue only. Results remain visible even with no writable filesystem.
- (void)recordPhotos:(NSDictionary *)result photo:(M7Photo *)photo {
    NSMutableDictionary *receipt = [result mutableCopy];
    receipt[@"filename"] = photo.filename;
    receipt[@"time"] = @(NSDate.date.timeIntervalSince1970);
    receipt[@"localBackup"] = @(photo.file != nil);
    self.photoResults[photo.filename] = receipt;
    if (self.photoResults.count > 12) {
        NSString *oldest = [self.photoResults.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [self.photoResults[a][@"time"] compare:self.photoResults[b][@"time"]];
        }].firstObject;
        [self.photoResults removeObjectForKey:oldest];
    }
    NSError *error = nil;
    if (photo.file) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:receipt options:NSJSONWritingPrettyPrinted error:&error];
        if (data) [data writeToURL:[photo.file URLByAppendingPathExtension:@"photos.json"] options:NSDataWritingAtomic error:&error];
    }
    if (photo.captureID > 0 && photo.captureID == self.captureID) [self recordCaptureStage:@"photos" details:receipt];
    if (error) [self recordCaptureStage:@"photosReceiptError" details:@{@"message":error.localizedDescription}];
}

- (void)photosFailed:(NSString *)reason photo:(M7Photo *)photo error:(NSError *)error {
    [self.photosInFlight removeObject:photo.filename];
    [self recordPhotos:@{@"state":@"failed", @"message":reason, @"domain":error.domain ?: @"",
        @"code":@(error.code), @"error":error.description ?: @""} photo:photo];
    if (photo.file) {
        photo.data = nil; // The existing file is the retry source.
        if (self.pendingPhoto == photo) self.pendingPhoto = nil;
    }
    if (photo.captureID == self.captureID || photo.captureID == -1) {
        NSString *location = photo.file ? @"Foto só no M7. Use Exportar." : @"Foto só na memória. Toque em SALVAR FOTO PENDENTE; não encerre a Câmera.";
        [self message:[NSString stringWithFormat:@"%@ %@", location, reason]];
    }
    if (photo.captureID == self.captureID) [self completeComparison:@"photosFailed"];
}

- (void)saveFileToPhotosIfAuthorized:(NSURL *)file captureID:(int64_t)captureID {
    M7Photo *photo = [M7Photo new];
    photo.file = file; photo.filename = file.lastPathComponent; photo.captureID = captureID;
    [self savePhotoToPhotos:photo];
}

- (void)savePhotoToPhotos:(M7Photo *)photo {
    if ([self.photosInFlight containsObject:photo.filename]) { [self message:@"Aguardando confirmação do Fotos…"]; return; }
    NSDictionary *receipt = self.photoResults[photo.filename];
    NSData *data = photo.file ? [NSData dataWithContentsOfURL:[photo.file URLByAppendingPathExtension:@"photos.json"]] : nil;
    if (data) receipt = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (([receipt isKindOfClass:NSDictionary.class] && [receipt[@"state"] isEqual:@"saved"]) || [self.photosImported containsObject:photo.filename]) {
        [self message:@"O Fotos já confirmou a inclusão desta foto."]; return;
    }
    [self.photosInFlight addObject:photo.filename];
    [self attemptPhotosImport:photo mayRequest:YES];
}

- (void)attemptPhotosImport:(M7Photo *)photo mayRequest:(BOOL)mayRequest {
    @try {
        if (!photo.data.length && (!photo.file || ![NSFileManager.defaultManager fileExistsAtPath:photo.file.path])) {
            [self photosFailed:@"Dados da foto indisponíveis. Abra Ver diagnóstico." photo:photo error:nil]; return;
        }
        PHAuthorizationStatus add = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        PHAuthorizationStatus read = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelReadWrite];
        NSString *usage = [NSBundle.mainBundle objectForInfoDictionaryKey:@"NSPhotoLibraryAddUsageDescription"];
        BOOL hasUsage = [usage isKindOfClass:NSString.class] && usage.length > 0;
        [self recordPhotos:@{@"state":@"authorization", @"addOnly":@(add), @"readWrite":@(read),
            @"hasAddUsageDescription":@(hasUsage)} photo:photo];
        BOOL authorized = add == PHAuthorizationStatusAuthorized || read == PHAuthorizationStatusAuthorized || read == PHAuthorizationStatusLimited;
        if (!authorized) {
            if (add == PHAuthorizationStatusNotDetermined && mayRequest && hasUsage) {
                [self message:@"Aguardando permissão para adicionar ao Fotos…"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(__unused PHAuthorizationStatus status) {
                        dispatch_async(self.sessionQueue, ^{ [self attemptPhotosImport:photo mayRequest:NO]; });
                    }];
                });
                return;
            }
            NSString *reason = add == PHAuthorizationStatusDenied ? @"Acesso ao Fotos negado." :
                add == PHAuthorizationStatusRestricted ? @"Acesso ao Fotos restrito pelo sistema." :
                @"O processo Câmera não forneceu autorização para adicionar ao Fotos.";
            [self photosFailed:reason photo:photo error:nil];
            return;
        }
        [self recordPhotos:@{@"state":@"importing", @"source":photo.data.length ? @"data" : @"file"} photo:photo];
        if (photo.captureID == self.captureID || photo.captureID == -1) [self message:@"Adicionando ao Fotos… Aguarde a confirmação."];
        // Capture strong references before handing off to PhotoKit's queue.
        NSData *payload = photo.data;
        NSURL *sourceFile = photo.file;
        __block NSString *assetID = nil;
        __block NSError *changeError = nil;
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            @try {
                PHAssetCreationRequest *asset = [PHAssetCreationRequest creationRequestForAsset];
                PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
                options.originalFilename = photo.filename;
                options.uniformTypeIdentifier = [photo.filename.pathExtension.lowercaseString isEqual:@"dng"] ? @"com.adobe.raw-image" : @"public.jpeg";
                if (payload.length) [asset addResourceWithType:PHAssetResourceTypePhoto data:payload options:options];
                else [asset addResourceWithType:PHAssetResourceTypePhoto fileURL:sourceFile options:options];
                assetID = asset.placeholderForCreatedAsset.localIdentifier;
            } @catch (NSException *exception) { changeError = [self captureExceptionError:exception]; }
        } completionHandler:^(BOOL success, NSError *saveError) {
            dispatch_async(self.sessionQueue, ^{
                [self.photosInFlight removeObject:photo.filename];
                if (!success || changeError || !assetID.length) {
                    NSError *failure = saveError ?: changeError;
                    [self photosFailed:[NSString stringWithFormat:@"Fotos: %@", failure.localizedDescription ?: @"não confirmou a inclusão"] photo:photo error:failure];
                    return;
                }
                [self.photosImported addObject:photo.filename];
                [self recordPhotos:@{@"state":@"saved", @"assetID":assetID} photo:photo];
                photo.data = nil;
                if (self.pendingPhoto == photo) self.pendingPhoto = nil;
                if (photo.captureID == self.captureID || photo.captureID == -1)
                    [self message:photo.file ? @"Salvo no Fotos. Cópia também disponível em Exportar." : @"Salvo no Fotos. Sem cópia local no M7."];
                if (photo.captureID == self.captureID) [self completeComparison:@"savedToPhotos"];
            });
        }];
    } @catch (NSException *exception) {
        [self photosFailed:@"Falha ao adicionar ao Fotos; abra Exportar → Ver diagnóstico." photo:photo error:[self captureExceptionError:exception]];
    }
}

- (NSDictionary *)sessionDiagnostic {
    AVCaptureDevice *device = self.input.device;
    NSMutableArray *outputs = [NSMutableArray new];
    for (AVCaptureOutput *output in self.session.outputs) [outputs addObject:NSStringFromClass(output.class)];
    CMVideoDimensions formatSize = {0, 0};
    if (device.activeFormat.formatDescription) formatSize = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription);
    return @{@"controllerID":self.controllerID, @"sessionID":self.sessionID, @"processID":@(getpid()),
        @"userID":@(getuid()), @"effectiveUserID":@(geteuid()),
        @"photoOnlyRequested":@(self.photoOnlyRequested), @"photoOnlyObserved":@([self isPhotoOnlySession]),
        @"comparisonID":self.comparisonReport[@"id"] ?: @"", @"comparisonActive":@(self.comparisonActive), @"configured":@(self.configured), @"running":@(self.session.isRunning),
        @"captureBusy":@(self.captureBusy), @"rawCaptureWaiting":@(self.rawCaptureWaiting),
        @"rawPreparationPending":@(self.rawPreparationPending), @"rawPrepared":@(self.rawPrepared),
        @"rawPreparation":self.rawPreparationReport ?: @{}, @"videoMode":@(self.videoModeActive),
        @"videoRecording":@(self.videoRecording), @"videoProcessing":@(self.videoProcessing),
        @"trackingEnabled":@(self.trackingEnabled), @"trackingPending":@(self.trackingPending),
        @"webcamEnabled":@(self.webcamEnabled), @"webcamEncoding":@(self.webcamEncoding),
        @"webcamRequested":@(self.webcamRequested),
        @"pairingScanning":@(self.pairingScanning), @"pairingAnalyzing":@(self.pairingAnalyzing),
        @"pairingSubmitting":@(self.pairingSubmitting),
        @"audioAttached":@([self.session.outputs containsObject:self.audioOutput]),
        @"videoOutputEnabled":@([self.videoOutput connectionWithMediaType:AVMediaTypeVideo].enabled),
        @"pendingExposure":@(self.pendingExposure),
        @"pendingFocus":@(self.pendingFocus), @"closing":@(self.closing), @"pendingPhotoBytes":@(self.pendingPhoto.data.length), @"captureID":@(self.captureID),
        @"outputs":outputs, @"preset":self.session.sessionPreset ?: @"", @"interrupted":@(self.session.isInterrupted),
        @"formatWidth":@(formatSize.width), @"formatHeight":@(formatSize.height),
        @"ISO":@(device.ISO), @"exposureMode":@(device.exposureMode), @"focusMode":@(device.focusMode),
        @"adjustingExposure":@(device.isAdjustingExposure), @"adjustingFocus":@(device.isAdjustingFocus),
        @"pressure":device.systemPressureState.level ?: @"", @"zoom":@(device.videoZoomFactor)};
}

// sessionQueue only: freeze before handing the report to the UI.
- (NSDictionary *)diagnosticSnapshot:(NSString *)origin status:(NSString *)visibleStatus {
    NSError *listError = nil;
    NSArray<NSURL *> *files = [self.storage imageFilesWithError:&listError];
    NSMutableArray *receipts = [NSMutableArray new];
    for (NSURL *file in [files subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, files.count))]) {
        NSData *data = [NSData dataWithContentsOfURL:[file URLByAppendingPathExtension:@"photos.json"]];
        id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        [receipts addObject:@{@"filename":file.lastPathComponent, @"photos":value ?: @{}}];
    }
    NSMutableDictionary *comparison = [self.comparisonReport mutableCopy] ?: [NSMutableDictionary new];
    if ([comparison[@"id"] isEqual:self.captureTrace[@"comparisonID"]]) {
        [comparison removeObjectForKey:@"capture"];
        comparison[@"captureReport"] = @"lastCapture";
    }
    __block NSDictionary *writer = @{};
    dispatch_sync(self.videoQueue, ^{ writer = self.videoRecorder ? [self.videoRecorder snapshot] : @{}; });
    __block NSDictionary *tracker = @{};
    dispatch_sync(self.trackingQueue, ^{ tracker = [self.subjectTracker snapshot]; });
    NSMutableArray *pendingVideoDetails = [NSMutableArray new];
    for (NSDictionary *item in self.pendingVideos) {
        NSURL *url = item[@"url"];
        [pendingVideoDetails addObject:@{@"label":item[@"label"] ?: @"", @"file":url ? M7VideoFileDetails(url) : @{}}];
    }
    NSDictionary *diagnostic = @{@"reportID":NSUUID.UUID.UUIDString, @"reportOrigin":origin, @"reportCreatedAt":@(NSDate.date.timeIntervalSince1970),
        @"lastComparison":comparison, @"sessionEvents":self.sessionEvents ?: @[], @"version":@"0.7.7", @"statusOnScreen":visibleStatus, @"sessionNow":[self sessionDiagnostic],
        @"lastVideo":self.videoTrace ?: @{}, @"videoWriterNow":writer, @"videoFormat":self.videoFormatDiagnostic ?: @{},
        @"trackingNow":@{ @"enabled":@(self.trackingEnabled), @"state":tracker },
        @"webcam":[self webcamSnapshot],
        @"pairing":[self.pairingManager snapshot], @"remoteStartup":self.remoteStartup ?: @{},
        @"remoteBindAttempts":self.remoteBindAttempts ?: @[],
        @"remoteServer":self.remoteServer.snapshot ?: @{}, @"remoteEvents":self.remoteEvents ?: @[],
        @"openSSH":self.openSSHStatus ?: @{},
        @"pendingVideos":pendingVideoDetails,
        @"storage":self.storage.attempts ?: @[], @"outputDirectory":self.outputDirectory.path ?: @"",
        @"localPhotoCount":@(files.count), @"listError":listError.localizedDescription ?: @"",
        @"lastCapture":self.captureTrace ?: @{@"message":@"Nenhuma tentativa registrada nesta instalação."},
        @"photos":receipts, @"recentPhotosResults":self.photoResults.allValues ?: @[], @"lens":self.lensDiagnostic ?: @{}};
    return M7JSONSnapshot(diagnostic);
}

- (void)showDiagnostic {
    NSString *visibleStatus = self.status.text ?: @"";
    dispatch_async(self.sessionQueue, ^{
        [self presentDiagnostic:[self diagnosticSnapshot:@"manual" status:visibleStatus]];
    });
}

- (void)presentDiagnostic:(NSDictionary *)diagnostic {
    [self presentDiagnostic:diagnostic revealed:NO];
}

// IPs are masked in the alert and in the copied text unless the user asks
// for them with "Mostrar IPs".
- (void)presentDiagnostic:(NSDictionary *)diagnostic revealed:(BOOL)revealed {
    NSData *json = [NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingPrettyPrinted error:nil];
    NSString *fullText = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"Falha ao montar diagnóstico.";
    NSString *text = revealed ? fullText : M7RedactIPv4(fullText);
    BOOL hasIPs = ![text isEqualToString:fullText];
    NSString *identifier = diagnostic[@"reportID"] ?: @"";
    NSString *shortID = [identifier substringToIndex:MIN((NSUInteger)8, identifier.length)];
    BOOL automatic = [diagnostic[@"reportOrigin"] isEqual:@"explicitDNGTest"];
    NSString *title = [NSString stringWithFormat:@"%@ · %@ · M7 0.7.7", automatic ? @"Teste RAW DNG" : @"Estado atual", shortID];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:revealed ? @"Copiar diagnóstico com IPs" : @"Copiar diagnóstico"
            style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = text;
            [self message:[NSString stringWithFormat:@"Relatório %@ copiado.", shortID]];
        }]];
        if (hasIPs) [alert addAction:[UIAlertAction actionWithTitle:@"Mostrar IPs" style:UIAlertActionStyleDefault
            handler:^(__unused UIAlertAction *action) { [self presentDiagnostic:diagnostic revealed:YES]; }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Fechar" style:UIAlertActionStyleCancel handler:nil]];
        [self presentExportController:alert];
    });
}

- (void)presentExportController:(UIViewController *)controller {
    [self presentExportController:controller attempt:0];
}

- (void)presentExportController:(UIViewController *)controller attempt:(NSUInteger)attempt {
    if (self.closing || self.isBeingDismissed || !self.view.window) return;
    controller.popoverPresentationController.sourceView = self.shareButton;
    UIViewController *presented = self.presentedViewController;
    if (presented.isBeingDismissed || self.isBeingPresented) {
        // Wait for UIAlertController's own action dismissal. Never dismiss M7
        // to replace a menu whose transition has already started.
        if (attempt >= 20) { [self message:@"Relatório disponível em Exportar → Ver diagnóstico."]; return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
            [self presentExportController:controller attempt:attempt + 1];
        });
    } else if (presented) {
        [presented dismissViewControllerAnimated:YES completion:^{
            [self presentExportController:controller attempt:attempt + 1];
        }];
    } else [self presentViewController:controller animated:YES completion:nil];
}

- (void)share {
    dispatch_async(self.sessionQueue, ^{
        NSError *error = nil;
        NSArray<NSURL *> *files = [self.storage imageFilesWithError:&error];
        BOOL pending = self.pendingPhoto != nil;
        BOOL pendingVideo = self.pendingVideos.count > 0;
        BOOL videoMode = self.videoModeActive;
        BOOL hasVideoOutput = [self.session.outputs containsObject:self.videoOutput];
        BOOL canRestore = self.photoOnlyRequested || !hasVideoOutput;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = error ? [NSString stringWithFormat:@"Falha ao ler uma pasta: %@", error.localizedDescription] :
                files.count ? @"Selecione uma foto para compartilhar ou adicionar ao Fotos." :
                pending ? @"Há uma foto aguardando inclusão no Fotos. Não encerre a Câmera." :
                @"Sem cópias locais. Capturas confirmadas ficam no app Fotos; o resultado aparece em Ver diagnóstico.";
            UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Exportar · M7 0.7.7" message:message preferredStyle:UIAlertControllerStyleActionSheet];
            [menu addAction:[UIAlertAction actionWithTitle:@"Ver diagnóstico" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self showDiagnostic]; }]];
            if (!videoMode) [menu addAction:[UIAlertAction actionWithTitle:@"Testar RAW DNG explícito" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) { [self runRAWComparison]; }]];
            [menu addAction:[UIAlertAction actionWithTitle:@"Último teste RAW DNG" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    NSDictionary *report;
                    @synchronized (M7CameraController.class) { report = M7LastTestReport; }
                    if (report) [self presentDiagnostic:report];
                    else [self message:@"Nenhum teste concluído neste processo da Câmera."];
                }]];
            if (!videoMode && canRestore) [menu addAction:[UIAlertAction actionWithTitle:@"Restaurar saída de peaking" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    dispatch_async(self.sessionQueue, ^{
                        if (self.captureBusy || self.pendingPhoto || self.comparisonActive || self.closing) {
                            [self message:@"Conclua o teste ou salve a foto pendente antes de restaurar."]; return;
                        }
                        [self configurePeakingOutput:YES];
                    });
                }]];
            if (pending) [menu addAction:[UIAlertAction actionWithTitle:@"Salvar foto pendente no Fotos" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                dispatch_async(self.sessionQueue, ^{ if (self.pendingPhoto) [self savePhotoToPhotos:self.pendingPhoto]; });
            }]];
            if (pendingVideo) [menu addAction:[UIAlertAction actionWithTitle:@"Tentar salvar vídeos pendentes" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) { dispatch_async(self.sessionQueue, ^{ [self retryPendingVideos]; }); }]];
            NSDateFormatter *formatter = [NSDateFormatter new];
            formatter.dateStyle = NSDateFormatterShortStyle; formatter.timeStyle = NSDateFormatterMediumStyle;
            for (NSURL *file in [files subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)12, files.count))]) {
                NSDate *date = nil; [file getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
                NSString *title = [NSString stringWithFormat:@"%@ · %@", file.pathExtension.uppercaseString, [formatter stringFromDate:date ?: NSDate.date]];
                [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self actionsForFile:file]; }]];
            }
            [menu addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
            [self presentExportController:menu];
        });
    });
}

- (BOOL)isPhotoOnlySession {
    NSArray *outputs = self.session.outputs;
    return outputs.count == 1 && outputs.firstObject == self.photoOutput;
}

- (void)recordSessionEvent:(NSString *)event details:(NSDictionary *)details {
    [self.sessionEvents addObject:@{@"event":event, @"time":@(NSDate.date.timeIntervalSince1970),
        @"sessionID":self.sessionID, @"details":M7JSONSnapshot(details)}];
    if (self.sessionEvents.count > 32) [self.sessionEvents removeObjectAtIndex:0];
}

// Does not toggle. Repeating the same requested mode is idempotent.
- (BOOL)configurePeakingOutput:(BOOL)attached {
    if (self.videoModeActive || !self.configured || !self.input || !self.videoOutput || self.captureBusy ||
        self.videoRecording || self.videoProcessing || self.pendingPhoto || self.closing) {
        [self recordSessionEvent:@"configurationRejected" details:[self sessionDiagnostic]];
        [self message:@"A sessão não está livre para reconfigurar. Consulte o diagnóstico."]; return NO;
    }
    if (!attached && self.webcamEnabled) {
        [self recordSessionEvent:@"configurationRejected" details:@{
            @"reason":@"webcamEnabled", @"session":[self sessionDiagnostic] }];
        [self message:@"Desligue a Webcam antes do teste RAW sem saída de vídeo."];
        return NO;
    }
    self.photoOnlyRequested = !attached;
    atomic_store(&M7PhotoOnlyPreferred, !attached);
    [self recordSessionEvent:@"configurationRequested" details:@{@"attachVideoOutput":@(attached), @"before":[self sessionDiagnostic]}];
    self.configured = NO; self.peakingEnabled = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ [self enableControls:NO]; self.peakingView.image = nil; });
    NSError *error = nil;
    BOOL ok = NO;
    @try {
        [self.session stopRunning];
        [self.session beginConfiguration];
        @try {
            if (attached) {
                if (![self.session.outputs containsObject:self.videoOutput] && [self.session canAddOutput:self.videoOutput])
                    [self.session addOutput:self.videoOutput];
            } else {
                // Validate actual topology, not only membership of a saved pointer.
                for (AVCaptureOutput *output in self.session.outputs)
                    if ([output isKindOfClass:AVCaptureVideoDataOutput.class]) [self.session removeOutput:output];
            }
        } @finally { [self.session commitConfiguration]; }
        AVCaptureDeviceType type = self.input.device.deviceType ?: AVCaptureDeviceTypeBuiltInWideAngleCamera;
        ok = [self selectDevice:type error:&error];
        if (ok) [self.session startRunning];
        self.configured = ok;
        ok = ok && self.session.isRunning && (attached ? [self.session.outputs containsObject:self.videoOutput] : [self isPhotoOnlySession]);
    } @catch (NSException *exception) { error = [self captureExceptionError:exception]; }
    BOOL hasVideo = [self.session.outputs containsObject:self.videoOutput];
    [self recordSessionEvent:@"configurationFinished" details:@{@"matched":@(ok), @"session":[self sessionDiagnostic], @"error":M7ErrorDetails(error)}];
    dispatch_async(dispatch_get_main_queue(), ^{ self.peakingSwitch.on = NO; self.peakingSwitch.enabled = hasVideo; });
    [self message:!ok ? @"A configuração solicitada não foi confirmada. Consulte o diagnóstico." :
        attached ? @"Saída de peaking restaurada. Exposição AUTO e foco AF." : @"Sessão sem peaking verificada. Preparando disparo RAW…"];
    return ok;
}

- (void)runRAWComparison {
    dispatch_async(self.sessionQueue, ^{
        if (self.videoModeActive || self.videoRecording || self.videoProcessing) {
            [self message:@"O teste RAW requer o modo Foto."]; return;
        }
        if (self.comparisonActive || self.captureBusy || self.pendingPhoto || self.closing) {
            [self message:@"Já existe uma captura ou foto pendente. Conclua-a antes do teste."]; return;
        }
        [self recordSessionEvent:@"explicitDNGTestRequested" details:[self sessionDiagnostic]];
        self.comparisonReport = [@{@"mode":@"explicitDNGPlusJPEG", @"id":NSUUID.UUID.UUIDString, @"startedAt":@(NSDate.date.timeIntervalSince1970),
            @"controllerID":self.controllerID, @"sessionID":self.sessionID, @"processID":@(getpid()),
            @"status":@"configuring", @"before":[self sessionDiagnostic]} mutableCopy];
        self.comparisonActive = YES;
        if (![self configurePeakingOutput:NO]) { [self completeComparison:@"configurationFailed"]; return; }
        self.comparisonReport[@"verifiedSession"] = M7JSONSnapshot([self sessionDiagnostic]);
        self.comparisonReport[@"status"] = @"capturing";
        // Request explicit DNG + JPEG in one exposure; only genuine RAW is saved.
        [self captureRAW:YES longEdge:0];
    });
}

- (void)completeComparison:(NSString *)outcome {
    if (!self.comparisonActive) return;
    self.comparisonActive = NO;
    self.comparisonReport[@"status"] = outcome;
    self.comparisonReport[@"finishedAt"] = @(NSDate.date.timeIntervalSince1970);
    self.comparisonReport[@"after"] = M7JSONSnapshot([self sessionDiagnostic]);
    if ([self.captureTrace[@"comparisonID"] isEqual:self.comparisonReport[@"id"]])
        self.comparisonReport[@"capture"] = M7JSONSnapshot(self.captureTrace);
    [self.storage writeJSON:self.comparisonReport filename:@"ultimo-teste-raw.json" error:nil];
    NSDictionary *report = [self diagnosticSnapshot:@"explicitDNGTest" status:outcome];
    @synchronized (M7CameraController.class) { M7LastTestReport = report; }
    [self presentDiagnostic:report];
}

- (void)actionsForFile:(NSURL *)file {
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:file.lastPathComponent message:@"O arquivo local é preservado após a exportação."
        preferredStyle:UIAlertControllerStyleActionSheet];
    [menu addAction:[UIAlertAction actionWithTitle:@"Adicionar ao Fotos" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        dispatch_async(self.sessionQueue, ^{ [self saveFileToPhotosIfAuthorized:file captureID:-1]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Compartilhar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self shareFile:file]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    [self presentExportController:menu];
}

- (void)shareFile:(NSURL *)file {
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) { [self message:@"Arquivo indisponível. Abra Exportar → Ver diagnóstico."]; return; }
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    [self presentExportController:sheet];
}

// videoQueue schedules at most one Vision request every 200 ms. Vision runs on
// its own serial queue so recording and peaking never wait for inference.
- (void)scheduleTrackingForSampleBuffer:(CMSampleBufferRef)sample {
    if (!self.trackingEnabled || self.trackingPending) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - self.lastTrackingTime < .2) return;
    CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
    if (!pixel) return;
    self.lastTrackingTime = now;
    self.trackingPending = YES;
    NSTimeInterval offset = self.videoRecording && self.videoRecorder ?
        [self.videoRecorder timeOffsetForSampleBuffer:sample] : -1;
    BOOL record = self.videoRecording && offset >= 0;
    CVPixelBufferRetain(pixel);
    dispatch_async(self.trackingQueue, ^{
        @autoreleasepool {
            NSDictionary *result = nil;
            @try {
                result = [self.subjectTracker analyzePixelBuffer:pixel timeOffset:offset record:record];
            } @catch (NSException *exception) {
                NSDictionary *state = [self.subjectTracker snapshot];
                result = @{ @"performed":@NO, @"detected":@NO, @"kind":@"exception",
                    @"centerX":state[@"centerX"] ?: @.5, @"centerY":state[@"centerY"] ?: @.5,
                    @"time":@(offset), @"error":M7ErrorDetails([self captureExceptionError:exception]) };
            }
            CVPixelBufferRelease(pixel);
            self.trackingPending = NO;
            CFTimeInterval errorNow = CACurrentMediaTime();
            if (result[@"error"] && record && errorNow-self.lastTrackingErrorLogTime >= 2) {
                self.lastTrackingErrorLogTime = errorNow;
                dispatch_async(self.sessionQueue, ^{
                    [self recordVideoStage:@"trackingAnalysisError" details:result];
                });
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self.trackingEnabled) return;
                self.trackingCenter = CGPointMake([result[@"centerX"] doubleValue],
                    [result[@"centerY"] doubleValue]);
                self.trackingDetected = [result[@"detected"] boolValue];
                [self updateReframeGuide];
            });
        }
    });
}

- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(__unused AVCaptureConnection *)connection {
    @autoreleasepool {
        AVMediaType mediaType = output == self.audioOutput ? AVMediaTypeAudio : AVMediaTypeVideo;
        if (self.videoRecording && self.videoRecorder) {
            NSError *writerError = [self.videoRecorder appendSampleBuffer:sample mediaType:mediaType];
            if (writerError) {
                dispatch_async(self.sessionQueue, ^{ [self stopVideoRecordingReason:@"writerFailure" error:writerError]; });
            }
        }
        if (output != self.videoOutput) return;
        [self scheduleTrackingForSampleBuffer:sample];
        [self scheduleWebcamForSampleBuffer:sample];
        [self schedulePairingForSampleBuffer:sample];
        CFTimeInterval now = CACurrentMediaTime();
        if (!self.peakingEnabled || self.overlayPending || now - self.lastPeakingTime < .1) return;
        self.lastPeakingTime = now;
        CVPixelBufferRef pixel = CMSampleBufferGetImageBuffer(sample);
        if (!pixel || CVPixelBufferGetPixelFormatType(pixel) != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            CVPixelBufferGetPlaneCount(pixel) < 1) return;
        if (CVPixelBufferLockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return;
        size_t sw = CVPixelBufferGetWidthOfPlane(pixel, 0), sh = CVPixelBufferGetHeightOfPlane(pixel, 0);
        size_t stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, 0);
        const uint8_t *source = CVPixelBufferGetBaseAddressOfPlane(pixel, 0);
        size_t step = MAX((size_t)1, (MAX(sw, sh) + 479) / 480);
        size_t w = sw / step, h = sh / step;
        NSMutableData *luma = [NSMutableData dataWithLength:w*h];
        uint8_t *dst = luma.mutableBytes;
        // Box-filter each reduced pixel to limit aliasing before edge detection.
        for (size_t y = 0; y < h; ++y) for (size_t x = 0; x < w; ++x) {
            unsigned sum = 0;
            for (size_t dy = 0; dy < step; ++dy) for (size_t dx = 0; dx < step; ++dx)
                sum += source[(y*step+dy)*stride+x*step+dx];
            dst[y*w+x] = (uint8_t)(sum / (step*step));
        }
        CVPixelBufferUnlockBaseAddress(pixel, kCVPixelBufferLock_ReadOnly);
        NSMutableData *rgba = [NSMutableData dataWithLength:w*h*4];
        if (!m7_peaking(dst, w, h, w, rgba.mutableBytes, w*4, self.peakingThreshold)) return;
        CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGImageRef cg = CGImageCreate(w, h, 8, 32, w*4, space,
            kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big, provider, NULL, false, kCGRenderingIntentDefault);
        UIImage *image = cg ? [UIImage imageWithCGImage:cg scale:1
            orientation:M7PreviewImageOrientation(self.cameraMount)] : nil;
        if (cg) CGImageRelease(cg);
        CGColorSpaceRelease(space); CGDataProviderRelease(provider);
        self.overlayPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.peakingView.image = self.peakingEnabled ? image : nil;
            self.overlayPending = NO;
        });
    }
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(__unused CMSampleBufferRef)sample
    fromConnection:(__unused AVCaptureConnection *)connection {
    if (output == self.videoOutput && self.videoRecording && self.videoRecorder)
        [self.videoRecorder noteDroppedVideoSample];
}

- (void)notification:(NSNotification *)note {
    if ([note.name hasPrefix:@"AVCaptureSession"] && note.object != self.session) return;
    if (self.closing) return;
    if ([note.name isEqualToString:NSProcessInfoThermalStateDidChangeNotification]) {
        NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
        double maxFPS = M7ThermalMaxWebcamFPS(thermal);
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:@"thermalStateChanged" details:@{ @"state":M7ThermalName(thermal),
                @"webcamMaxFPS":@(maxFPS), @"webcamEnabled":@(self.webcamEnabled) }];
        });
        if (self.webcamEnabled) [self message:maxFPS > 0 ?
            [NSString stringWithFormat:@"iPhone quente: webcam limitada a %.0f fps.", maxFPS] :
            @"Temperatura normal: webcam de volta a 30 fps."];
        return;
    }
    if ([note.name isEqualToString:UIApplicationWillResignActiveNotification]) {
        self.peakingView.image = nil;
        [self cancelPairing:@"applicationBackground"];
        if (self.webcamSwitch.on) { self.webcamSwitch.on = NO; [self changeWebcam]; }
        [self stopRemoteServerReason:@"applicationBackground"];
        [self setRemoteStatus:@"Pausado" color:UIColor.systemYellowColor showsPIN:YES];
        dispatch_async(self.sessionQueue, ^{
            if (self.videoRecording) [self stopVideoRecordingReason:@"applicationBackground" error:nil];
            [self.session stopRunning];
            [self recordSessionEvent:@"applicationBackground" details:[self sessionDiagnostic]];
        });
    } else if ([note.name isEqualToString:UIApplicationDidBecomeActiveNotification] ||
               [note.name isEqualToString:AVCaptureSessionInterruptionEndedNotification]) {
        [self scheduleRemoteServerStart:@"applicationActive"];
        dispatch_async(self.sessionQueue, ^{
            if (self.configured && !self.closing) {
                [self.session startRunning];
                ++self.exposureRevision; ++self.focusRevision;
                self.pendingExposure = NO; self.pendingFocus = NO;
            }
        });
    } else if ([note.name isEqualToString:AVCaptureSessionRuntimeErrorNotification]) {
        [self cancelPairing:@"sessionError"];
        NSError *error = note.userInfo[AVCaptureSessionErrorKey];
        [self message:[NSString stringWithFormat:@"Câmera: %@. Feche e reabra M7.", error.localizedDescription ?: @"erro de sessão"]];
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:@"sessionError" details:M7ErrorDetails(error)];
            if (self.videoRecording) [self stopVideoRecordingReason:@"sessionError" error:error];
            [self completeComparison:@"sessionError"];
            self.configured = NO; self.captureBusy = NO;
            self.pendingExposure = NO; self.pendingFocus = NO;
            ++self.exposureRevision; ++self.focusRevision;
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = YES; });
        });
    } else if ([note.name isEqualToString:AVCaptureSessionWasInterruptedNotification]) {
        [self cancelPairing:@"sessionInterrupted"];
        [self message:@"Câmera interrompida; aguardando disponibilidade."];
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:@"sessionInterrupted" details:note.userInfo ?: @{}];
            if (self.videoRecording) [self stopVideoRecordingReason:@"sessionInterrupted" error:nil];
        });
    }
}

- (void)close {
    if (self.closing) return;
    self.closeButton.enabled = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.videoRecording) {
            [self stopVideoRecordingReason:@"closeRequested" error:nil];
            [self message:@"A gravação foi encerrada; aguarde o processamento antes de fechar."];
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = NO; });
            return;
        }
        if (self.videoProcessing) {
            [self message:@"Aguarde a exportação e a confirmação do Fotos."];
            return;
        }
        if (self.captureBusy) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = YES; });
            return;
        }
        if (self.pendingVideos.count) {
            NSArray *pending = [self.pendingVideos copy];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.closeButton.enabled = YES;
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Vídeos ainda não salvos"
                    message:@"Há vídeos apenas na pasta temporária. Tente salvá-los no Fotos antes de fechar."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Continuar no M7" style:UIAlertActionStyleCancel handler:nil]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Tentar salvar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                    dispatch_async(self.sessionQueue, ^{ [self retryPendingVideos]; });
                }]];
                [alert addAction:[UIAlertAction actionWithTitle:@"Descartar vídeos e fechar" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                    dispatch_async(self.sessionQueue, ^{
                        for (NSDictionary *item in pending) {
                            NSURL *url = item[@"url"];
                            if (url) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
                        }
                        [self.pendingVideos removeObjectsInArray:pending];
                        [self recordVideoStage:@"pendingVideosDiscarded" details:@{@"count":@(pending.count)}];
                        dispatch_async(dispatch_get_main_queue(), ^{ [self close]; });
                    });
                }]];
                [self presentExportController:alert];
            });
            return;
        }
        if (self.pendingPhoto && !self.pendingPhoto.file && self.pendingPhoto.data.length) {
            M7Photo *photo = self.pendingPhoto;
            BOOL importing = [self.photosInFlight containsObject:photo.filename];
            dispatch_async(dispatch_get_main_queue(), ^{
                self.closeButton.enabled = YES;
                UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Foto ainda não salva"
                    message:importing ? @"O Fotos ainda não confirmou a inclusão. Aguarde para fechar o M7." :
                        @"Esta foto está apenas na memória. Fechar agora descarta a imagem."
                    preferredStyle:UIAlertControllerStyleAlert];
                [alert addAction:[UIAlertAction actionWithTitle:@"Continuar no M7" style:UIAlertActionStyleCancel handler:nil]];
                if (!importing) {
                    [alert addAction:[UIAlertAction actionWithTitle:@"Tentar salvar" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
                        dispatch_async(self.sessionQueue, ^{ if (self.pendingPhoto == photo) [self savePhotoToPhotos:photo]; });
                    }]];
                    [alert addAction:[UIAlertAction actionWithTitle:@"Descartar foto e fechar" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
                        dispatch_async(self.sessionQueue, ^{
                            if (self.pendingPhoto == photo && ![self.photosInFlight containsObject:photo.filename]) {
                                [self recordPhotos:@{@"state":@"discardedByUser"} photo:photo];
                                photo.data = nil; self.pendingPhoto = nil;
                                dispatch_async(dispatch_get_main_queue(), ^{ [self close]; });
                            }
                        });
                    }]];
                }
                [self presentExportController:alert];
            });
            return;
        }
        self.closing = YES;
        [self cancelPairing:@"controllerClosed"];
        self.webcamRequested = NO;
        self.webcamEnabled = NO;
        dispatch_async(self.webcamQueue, ^{ [self.webcamServer stop]; });
        [self stopRemoteServerReason:@"controllerClosed"];
        [self.session stopRunning];
        [self.videoOutput setSampleBufferDelegate:nil queue:NULL];
        [self.audioOutput setSampleBufferDelegate:nil queue:NULL];
        [self endVideoBackgroundTask];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self keepScreenAwakeForWebcam:NO];
            [self.timer invalidate]; self.peakingEnabled = NO;
            [self dismissViewControllerAnimated:YES completion:^{
                BOOL foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
                dispatch_async(self.sessionQueue, ^{ M7EndCameraOwnership(foreground); });
            }];
        });
    });
}

- (void)dealloc {
    [_pairingManager cancel];
    [_remoteServer stop];
    [_webcamServer stop];
    [_timer invalidate];
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
}
@end
