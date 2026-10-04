#import "M7CameraController.h"
#import "M7DeviceControls.h"
#import "M7JPEG.h"
#import "M7Storage.h"
#import "M7ErrorDetails.h"
#import "M7CaptureResult.h"
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

@interface M7CameraController () <M7RequiredPhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) dispatch_queue_t videoQueue;
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *input;
@property (nonatomic) AVCapturePhotoOutput *photoOutput;
@property (nonatomic) AVCaptureVideoDataOutput *videoOutput;
@property (nonatomic) M7DeviceControls *controls;
@property (nonatomic) AVCaptureVideoPreviewLayer *preview;
@property (nonatomic) UIView *previewView;
@property (nonatomic) UIImageView *peakingView;
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
@end

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
    self.videoQueue = dispatch_queue_create("dev.manual7.peaking", DISPATCH_QUEUE_SERIAL);
    self.controllerID = NSUUID.UUID.UUIDString;
    self.sessionID = NSUUID.UUID.UUIDString;
    self.photoOnlyRequested = atomic_load(&M7PhotoOnlyPreferred);
    self.sessionEvents = [NSMutableArray new];
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
    [self.view addSubview:scroll];
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 3; stack.translatesAutoresizingMaskIntoConstraints = NO;
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
    self.readout = [UILabel new]; self.readout.numberOfLines = 2;
    self.readout.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.readout.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:self.readout];
    self.status = [UILabel new]; self.status.numberOfLines = 3;
    self.status.font = [UIFont systemFontOfSize:12]; self.status.textColor = UIColor.systemYellowColor;
    self.status.text = @"Preparando câmera…";
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.status];

    self.lens = [[UISegmentedControl alloc] initWithItems:@[@"1×", @"2×"]]; self.lens.selectedSegmentIndex = 0;
    [self.lens addTarget:self action:@selector(changeLens) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self row:@"Lente" control:self.lens]];
    self.exposureMode = [[UISegmentedControl alloc] initWithItems:@[@"AUTO", @"M", @"AE-L"]];
    self.exposureMode.selectedSegmentIndex = 0;
    [self.exposureMode addTarget:self action:@selector(changeExposureMode) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self row:@"Exposição" control:self.exposureMode]];
    self.isoSlider = [self slider:@"ISO manual" action:@selector(changeManualExposure)];
    self.shutterSlider = [self slider:@"Obturador em terços de stop" action:@selector(changeManualExposure)];
    [stack addArrangedSubview:[self row:@"ISO" control:self.isoSlider]];
    [stack addArrangedSubview:[self row:@"Shutter" control:self.shutterSlider]];
    self.evStepper = [UIStepper new]; self.evStepper.stepValue = 1;
    self.evStepper.accessibilityLabel = @"Compensação EV em terços de stop";
    [self.evStepper addTarget:self action:@selector(changeEV) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self row:@"EV ±⅓" control:self.evStepper]];
    self.focusMode = [[UISegmentedControl alloc] initWithItems:@[@"AF", @"MF", @"AF-L"]];
    self.focusMode.selectedSegmentIndex = 0;
    [self.focusMode addTarget:self action:@selector(changeFocusMode) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self row:@"Foco" control:self.focusMode]];
    self.focusSlider = [self slider:@"Posição do foco de perto a longe" action:@selector(changeManualFocus)];
    self.focusSlider.continuous = YES;
    [self.focusSlider addTarget:self action:@selector(changeManualFocus)
        forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    [stack addArrangedSubview:[self row:@"Perto/longe" control:self.focusSlider]];
    self.rawSwitch = [UISwitch new]; self.rawSwitch.on = YES;
    [self.rawSwitch addTarget:self action:@selector(updateSizeControl) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self row:@"DNG RAW" control:self.rawSwitch]];
    self.sizeButton = [self button:@"Original" action:@selector(chooseJPEGSize)];
    self.sizeButton.accessibilityLabel = @"Tamanho da fotografia JPEG";
    [stack addArrangedSubview:[self row:@"Tamanho" control:self.sizeButton]];
    self.peakingSwitch = [UISwitch new];
    [self.peakingSwitch addTarget:self action:@selector(changePeaking) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:[self row:@"Peaking" control:self.peakingSwitch]];
    self.thresholdSlider = [self slider:@"Limiar do focus peaking" action:@selector(changePeaking)];
    self.thresholdSlider.minimumValue = .03; self.thresholdSlider.maximumValue = .6; self.thresholdSlider.value = .2;
    [stack addArrangedSubview:[self row:@"Limiar" control:self.thresholdSlider]];

    self.shutterButton = [self button:@"●  FOTOGRAFAR" action:@selector(capture)];
    self.shutterButton.titleLabel.font = [UIFont systemFontOfSize:19 weight:UIFontWeightSemibold];
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
        [scroll.topAnchor constraintEqualToAnchor:self.previewView.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.status.topAnchor constant:-4],
        [self.status.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.status.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.status.bottomAnchor constraintEqualToAnchor:self.shutterButton.topAnchor],
        [self.status.heightAnchor constraintEqualToConstant:48],
        [self.shutterButton.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [self.shutterButton.trailingAnchor constraintEqualToAnchor:top.trailingAnchor],
        [self.shutterButton.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [self.shutterButton.heightAnchor constraintEqualToConstant:54],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor]]];
    [self enableControls:NO];
    __weak typeof(self) weakSelf = self;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:.3 repeats:YES block:^(__unused NSTimer *t) {
        [weakSelf refresh];
    }];
    NSMutableArray *observers = [NSMutableArray new];
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationWillResignActiveNotification,
          UIApplicationDidBecomeActiveNotification, AVCaptureSessionWasInterruptedNotification,
          AVCaptureSessionInterruptionEndedNotification, AVCaptureSessionRuntimeErrorNotification]) {
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
        self.photoOutput.highResolutionCaptureEnabled = YES;
        self.videoOutput = [AVCaptureVideoDataOutput new];
        self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
        self.videoOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)};
        [self.videoOutput setSampleBufferDelegate:self queue:self.videoQueue];
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
}

- (void)message:(NSString *)text {
    dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = text; });
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
    self.captureTrace[@"version"] = @"0.1.6";
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
    self.sizeButton.enabled = self.captureAvailable && !self.rawSwitch.on;
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
        if (c.isVideoOrientationSupported) c.videoOrientation = AVCaptureVideoOrientationPortrait;
        if (c.isVideoStabilizationSupported) c.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeOff;
    }
    NSMutableDictionary *limits = [self.controls.capabilities mutableCopy];
    CMVideoDimensions native = device.activeFormat.highResolutionStillImageDimensions;
    limits[@"nativeWidth"] = @(native.width); limits[@"nativeHeight"] = @(native.height);
    int selected = 0;
    m7_shutter_nearest(CMTimeGetSeconds(device.exposureDuration),
        CMTimeGetSeconds(device.activeFormat.minExposureDuration),
        CMTimeGetSeconds(device.activeFormat.maxExposureDuration), &selected);
    float isoPosition = (log(device.ISO) - log(device.activeFormat.minISO)) /
        fmax(1e-9, log(device.activeFormat.maxISO) - log(device.activeFormat.minISO));
    BOOL raw = [self.controls rawSettingsForOutput:self.photoOutput error:nil] != nil;
    NSMutableDictionary *diagnostic = [limits mutableCopy];
    diagnostic[@"systemVersion"] = UIDevice.currentDevice.systemVersion;
    diagnostic[@"rawFormats"] = self.photoOutput.availableRawPhotoPixelFormatTypes;
    diagnostic[@"version"] = @"0.1.6";
    self.lensDiagnostic = diagnostic;
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

- (void)enableControls:(BOOL)ready {
    self.captureAvailable = ready;
    self.lens.enabled = ready;
    self.exposureMode.enabled = ready; self.focusMode.enabled = ready;
    BOOL manual = ready && self.exposureMode.selectedSegmentIndex == 1 && [self.limits[@"manualExposure"] boolValue];
    self.isoSlider.enabled = manual;
    self.shutterSlider.enabled = manual && [self.limits[@"hasShutterGrid"] boolValue];
    self.focusSlider.enabled = ready && self.focusMode.selectedSegmentIndex == 1 && [self.limits[@"manualFocus"] boolValue];
    self.evStepper.enabled = ready && self.exposureMode.selectedSegmentIndex == 0;
    self.shutterButton.enabled = ready;
    [self updateSizeControl];
}

- (void)refresh {
    if (self.closing) return;
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice *d = self.input.device;
        BOOL ready = self.configured && self.session.isRunning && !self.captureBusy;
        BOOL pending = self.pendingPhoto != nil;
        BOOL importing = pending && [self.photosInFlight containsObject:self.pendingPhoto.filename];
        BOOL settled = !self.pendingExposure && !self.pendingFocus;
        double seconds = CMTimeGetSeconds(d.exposureDuration);
        NSString *shutter = seconds > 0 && seconds < 1 ? [NSString stringWithFormat:@"1/%.1f s", 1 / seconds] : [NSString stringWithFormat:@"%.4f s", seconds];
        NSString *readout = d ? [NSString stringWithFormat:@"ISO %.0f · %@ · f/%.1f\nEV %+.2f · Medidor %+.2f EV · Foco %.2f", d.ISO, shutter, d.lensAperture, d.exposureTargetBias, d.exposureTargetOffset, d.lensPosition] : @"Sem câmera ativa";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableControls:ready && !pending];
            self.shutterButton.enabled = pending ? !importing : ready && settled;
            NSString *title = importing ? @"Salvando no Fotos…" : pending ? @"SALVAR FOTO PENDENTE" :
                ready && !settled ? @"Aguardando foco/exposição…" : @"●  FOTOGRAFAR";
            [self.shutterButton setTitle:title forState:UIControlStateNormal];
            self.readout.text = readout;
        });
    });
}

- (void)changeLens {
    AVCaptureDeviceType type = self.lens.selectedSegmentIndex ? AVCaptureDeviceTypeBuiltInTelephotoCamera : AVCaptureDeviceTypeBuiltInWideAngleCamera;
    [self enableControls:NO]; self.peakingView.image = nil;
    dispatch_async(self.sessionQueue, ^{
        if (self.captureBusy || self.closing) return;
        NSError *error = nil;
        if (![self selectDevice:type error:&error]) {
            [self message:error.localizedDescription];
            BOOL tele = [self.input.device.deviceType isEqualToString:AVCaptureDeviceTypeBuiltInTelephotoCamera];
            dispatch_async(dispatch_get_main_queue(), ^{ self.lens.selectedSegmentIndex = tele ? 1 : 0; });
        } else [self message:@"Lente alterada; exposição e foco voltaram para AUTO."];
    });
}

- (void)changeExposureMode {
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
        __weak typeof(self) weakSelf = self;
        BOOL ok = [self.controls setISO:(float)iso shutterIndex:index completion:^(__unused CMTime time) {
            typeof(self) owner = weakSelf; if (!owner) return;
            dispatch_async(owner.sessionQueue, ^{ if (owner.exposureRevision == revision) owner.pendingExposure = NO; });
        } error:&error];
        if (!ok) { self.pendingExposure = NO; [self message:error.localizedDescription]; }
    });
}

- (void)changeFocusMode {
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
        __weak typeof(self) weakSelf = self;
        BOOL ok = [self.controls setManualFocus:position completion:^(__unused CMTime time) {
            typeof(self) owner = weakSelf; if (!owner) return;
            dispatch_async(owner.sessionQueue, ^{ if (owner.focusRevision == revision) owner.pendingFocus = NO; });
        } error:&error];
        if (!ok) { self.pendingFocus = NO; [self message:error.localizedDescription]; }
    });
}

- (void)changeEV {
    NSInteger thirds = (NSInteger)self.evStepper.value;
    dispatch_async(self.sessionQueue, ^{
        if (self.captureBusy || self.closing) return;
        NSError *error = nil;
        NSUInteger revision = ++self.exposureRevision; self.pendingExposure = YES;
        __weak typeof(self) weakSelf = self;
        BOOL ok = [self.controls setExposureBiasThirds:thirds completion:^(__unused CMTime time) {
            typeof(self) owner = weakSelf; if (!owner) return;
            dispatch_async(owner.sessionQueue, ^{ if (owner.exposureRevision == revision) owner.pendingExposure = NO; });
        } error:&error];
        if (!ok) {
            self.pendingExposure = NO;
            [self message:error.localizedDescription ?: @"Câmera ainda não está pronta."];
        }
    });
}

- (void)changePeaking {
    self.peakingEnabled = self.peakingSwitch.on;
    self.peakingThreshold = self.thresholdSlider.value;
    if (!self.peakingEnabled) self.peakingView.image = nil;
}

- (void)capture {
    BOOL raw = self.rawSwitch.on;
    NSUInteger longEdge = raw ? 0 : self.jpegLongEdge;
    dispatch_async(self.sessionQueue, ^{
        if (self.comparisonActive) { [self message:@"Teste RAW em andamento; aguarde o relatório."]; return; }
        [self captureRAW:raw longEdge:longEdge];
    });
}

// sessionQueue only. Test configuration and submission run in one operation.
- (void)captureRAW:(BOOL)raw longEdge:(NSUInteger)longEdge {

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
        [self recordCaptureStage:@"requested" details:@{@"raw":@(raw), @"jpegLongEdge":@(longEdge),
            @"device":self.input.device.deviceType ?: @"", @"highResolutionEnabled":@(self.photoOutput.isHighResolutionCaptureEnabled),
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
            AVCapturePhotoSettings *settings = raw ? [self.controls rawSettingsForOutput:self.photoOutput error:&error] :
                [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}];
            if (!settings) { [self finishCaptureWithError:error]; return; }
            // Only the explicit compatibility test requests a processed companion.
            if (raw && self.comparisonActive) {
                if (![self.photoOutput.availablePhotoCodecTypes containsObject:AVVideoCodecTypeJPEG])
                    [NSException raise:NSInvalidArgumentException format:@"JPEG de comparação indisponível."];
                settings = [AVCapturePhotoSettings photoSettingsWithRawPixelFormatType:settings.rawPhotoPixelFormatType
                    processedFormat:@{AVVideoCodecKey:AVVideoCodecTypeJPEG}];
            }
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
            [self recordCaptureStage:@"submit" details:@{@"id":@(settings.uniqueID),
                @"rawFormat":@(settings.rawPhotoPixelFormatType), @"processedFormat":settings.format ?: @{},
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
        @"photoOnlyRequested":@(self.photoOnlyRequested), @"photoOnlyObserved":@([self isPhotoOnlySession]),
        @"comparisonID":self.comparisonReport[@"id"] ?: @"", @"comparisonActive":@(self.comparisonActive), @"configured":@(self.configured), @"running":@(self.session.isRunning),
        @"captureBusy":@(self.captureBusy), @"pendingExposure":@(self.pendingExposure),
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
    NSDictionary *diagnostic = @{@"reportID":NSUUID.UUID.UUIDString, @"reportOrigin":origin, @"reportCreatedAt":@(NSDate.date.timeIntervalSince1970),
        @"lastComparison":comparison, @"sessionEvents":self.sessionEvents ?: @[], @"version":@"0.1.6", @"statusOnScreen":visibleStatus, @"sessionNow":[self sessionDiagnostic],
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
    NSData *json = [NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingPrettyPrinted error:nil];
    NSString *text = json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"Falha ao montar diagnóstico.";
    NSString *identifier = diagnostic[@"reportID"] ?: @"";
    NSString *shortID = [identifier substringToIndex:MIN((NSUInteger)8, identifier.length)];
    BOOL automatic = [diagnostic[@"reportOrigin"] isEqual:@"rawJPEGTest"];
    NSString *title = [NSString stringWithFormat:@"%@ · %@ · M7 0.1.6", automatic ? @"Teste RAW + JPEG" : @"Estado atual", shortID];
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:text preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Copiar diagnóstico" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = text;
            [self message:[NSString stringWithFormat:@"Relatório %@ copiado.", shortID]];
        }]];
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
        BOOL hasVideoOutput = [self.session.outputs containsObject:self.videoOutput];
        BOOL canRestore = self.photoOnlyRequested || !hasVideoOutput;
        dispatch_async(dispatch_get_main_queue(), ^{
            NSString *message = error ? [NSString stringWithFormat:@"Falha ao ler uma pasta: %@", error.localizedDescription] :
                files.count ? @"Selecione uma foto para compartilhar ou adicionar ao Fotos." :
                pending ? @"Há uma foto aguardando inclusão no Fotos. Não encerre a Câmera." :
                @"Sem cópias locais. Capturas confirmadas ficam no app Fotos; o resultado aparece em Ver diagnóstico.";
            UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Exportar · M7 0.1.6" message:message preferredStyle:UIAlertControllerStyleActionSheet];
            [menu addAction:[UIAlertAction actionWithTitle:@"Ver diagnóstico" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) { [self showDiagnostic]; }]];
            [menu addAction:[UIAlertAction actionWithTitle:@"Testar RAW + JPEG (compatibilidade)" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) { [self runRAWComparison]; }]];
            [menu addAction:[UIAlertAction actionWithTitle:@"Último teste RAW + JPEG" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    NSDictionary *report;
                    @synchronized (M7CameraController.class) { report = M7LastTestReport; }
                    if (report) [self presentDiagnostic:report];
                    else [self message:@"Nenhum teste concluído neste processo da Câmera."];
                }]];
            if (canRestore) [menu addAction:[UIAlertAction actionWithTitle:@"Restaurar saída de peaking" style:UIAlertActionStyleDefault
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
    if (self.sessionEvents.count > 8) [self.sessionEvents removeObjectAtIndex:0];
}

// Does not toggle. Repeating the same requested mode is idempotent.
- (BOOL)configurePeakingOutput:(BOOL)attached {
    if (!self.configured || !self.input || !self.videoOutput || self.captureBusy || self.pendingPhoto || self.closing) {
        [self recordSessionEvent:@"configurationRejected" details:[self sessionDiagnostic]];
        [self message:@"A sessão não está livre para reconfigurar. Consulte o diagnóstico."]; return NO;
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
        if (self.comparisonActive || self.captureBusy || self.pendingPhoto || self.closing) {
            [self message:@"Já existe uma captura ou foto pendente. Conclua-a antes do teste."]; return;
        }
        [self recordSessionEvent:@"rawJPEGTestRequested" details:[self sessionDiagnostic]];
        self.comparisonReport = [@{@"mode":@"rawPlusJPEG", @"id":NSUUID.UUID.UUIDString, @"startedAt":@(NSDate.date.timeIntervalSince1970),
            @"controllerID":self.controllerID, @"sessionID":self.sessionID, @"processID":@(getpid()),
            @"status":@"configuring", @"before":[self sessionDiagnostic]} mutableCopy];
        self.comparisonActive = YES;
        if (![self configurePeakingOutput:NO]) { [self completeComparison:@"configurationFailed"]; return; }
        self.comparisonReport[@"verifiedSession"] = M7JSONSnapshot([self sessionDiagnostic]);
        self.comparisonReport[@"status"] = @"capturing";
        // Request RAW + JPEG in the same exposure; only genuine RAW is saved.
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
    NSDictionary *report = [self diagnosticSnapshot:@"rawJPEGTest" status:outcome];
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

- (void)captureOutput:(__unused AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(__unused AVCaptureConnection *)connection {
    @autoreleasepool {
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
        UIImage *image = cg ? [UIImage imageWithCGImage:cg] : nil;
        if (cg) CGImageRelease(cg);
        CGColorSpaceRelease(space); CGDataProviderRelease(provider);
        self.overlayPending = YES;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.peakingView.image = self.peakingEnabled ? image : nil;
            self.overlayPending = NO;
        });
    }
}

- (void)notification:(NSNotification *)note {
    if ([note.name hasPrefix:@"AVCaptureSession"] && note.object != self.session) return;
    if (self.closing) return;
    if ([note.name isEqualToString:UIApplicationWillResignActiveNotification]) {
        self.peakingView.image = nil;
        dispatch_async(self.sessionQueue, ^{ [self.session stopRunning]; });
    } else if ([note.name isEqualToString:UIApplicationDidBecomeActiveNotification] ||
               [note.name isEqualToString:AVCaptureSessionInterruptionEndedNotification]) {
        dispatch_async(self.sessionQueue, ^{
            if (self.configured && !self.closing) {
                [self.session startRunning];
                ++self.exposureRevision; ++self.focusRevision;
                self.pendingExposure = NO; self.pendingFocus = NO;
            }
        });
    } else if ([note.name isEqualToString:AVCaptureSessionRuntimeErrorNotification]) {
        NSError *error = note.userInfo[AVCaptureSessionErrorKey];
        [self message:[NSString stringWithFormat:@"Câmera: %@. Feche e reabra M7.", error.localizedDescription ?: @"erro de sessão"]];
        dispatch_async(self.sessionQueue, ^{
            [self recordSessionEvent:@"sessionError" details:M7ErrorDetails(error)];
            [self completeComparison:@"sessionError"];
            self.configured = NO; self.captureBusy = NO;
            self.pendingExposure = NO; self.pendingFocus = NO;
            ++self.exposureRevision; ++self.focusRevision;
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = YES; });
        });
    } else if ([note.name isEqualToString:AVCaptureSessionWasInterruptedNotification]) {
        [self message:@"Câmera interrompida; aguardando disponibilidade."];
    }
}

- (void)close {
    if (self.closing) return;
    self.closeButton.enabled = NO;
    dispatch_async(self.sessionQueue, ^{
        if (self.captureBusy) {
            dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = YES; });
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
        [self.session stopRunning];
        [self.videoOutput setSampleBufferDelegate:nil queue:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.timer invalidate]; self.peakingEnabled = NO;
            [self dismissViewControllerAnimated:YES completion:^{
                BOOL foreground = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
                dispatch_async(self.sessionQueue, ^{ M7EndCameraOwnership(foreground); });
            }];
        });
    });
}

- (void)dealloc {
    [_timer invalidate];
    for (id observer in _observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
}
@end
