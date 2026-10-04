#import "M7CameraController.h"
#import "M7DeviceControls.h"
#import "../Core/M7Math.h"
#import <Photos/Photos.h>
#import <QuartzCore/QuartzCore.h>

@interface M7CameraController () <AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>
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
    self.session = [AVCaptureSession new]; M7MarkSessionOwned(self.session);
    self.peakingThreshold = .2;

    self.closeButton = [self button:@"Fechar" action:@selector(close)];
    self.shareButton = [self button:@"Exportar" action:@selector(share)];
    self.shareButton.enabled = NO;
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
    self.status = [UILabel new]; self.status.numberOfLines = 0;
    self.status.font = [UIFont systemFontOfSize:12]; self.status.textColor = UIColor.systemYellowColor;
    self.status.text = @"Preparando câmera…";
    [stack addArrangedSubview:self.status];

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
    [stack addArrangedSubview:[self row:@"DNG RAW" control:self.rawSwitch]];
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
        [scroll.bottomAnchor constraintEqualToAnchor:self.shutterButton.topAnchor],
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
        BOOL videoOK = [self.session canAddOutput:self.videoOutput];
        if (videoOK) [self.session addOutput:self.videoOutput];
        [self.session commitConfiguration];
        if (!outputsOK || ![self selectDevice:AVCaptureDeviceTypeBuiltInWideAngleCamera error:&error]) {
            [self message:error.localizedDescription ?: @"Não foi possível configurar a captura."]; return;
        }
        self.configured = YES;
        [self.session startRunning];
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
    return [[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
        URLByAppendingPathComponent:@"Manual7" isDirectory:YES];
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
    NSDictionary *limits = self.controls.capabilities;
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
    diagnostic[@"version"] = @"0.1.0";
    NSURL *directory = self.outputDirectory;
    [NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSData *json = [NSJSONSerialization dataWithJSONObject:diagnostic options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToURL:[directory URLByAppendingPathComponent:@"diagnostico.json"] atomically:YES];
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
        self.peakingView.image = nil;
        self.shareButton.enabled = YES;
    });
    return YES;
}

- (void)enableControls:(BOOL)ready {
    self.lens.enabled = ready;
    self.exposureMode.enabled = ready; self.focusMode.enabled = ready;
    BOOL manual = ready && self.exposureMode.selectedSegmentIndex == 1 && [self.limits[@"manualExposure"] boolValue];
    self.isoSlider.enabled = manual;
    self.shutterSlider.enabled = manual && [self.limits[@"hasShutterGrid"] boolValue];
    self.focusSlider.enabled = ready && self.focusMode.selectedSegmentIndex == 1 && [self.limits[@"manualFocus"] boolValue];
    self.evStepper.enabled = ready && self.exposureMode.selectedSegmentIndex == 0;
    self.shutterButton.enabled = ready;
}

- (void)refresh {
    if (self.closing) return;
    dispatch_async(self.sessionQueue, ^{
        AVCaptureDevice *d = self.input.device;
        BOOL ready = self.configured && self.session.isRunning && !self.captureBusy;
        BOOL settled = !self.pendingExposure && !self.pendingFocus;
        double seconds = CMTimeGetSeconds(d.exposureDuration);
        NSString *shutter = seconds > 0 && seconds < 1 ? [NSString stringWithFormat:@"1/%.1f s", 1 / seconds] : [NSString stringWithFormat:@"%.4f s", seconds];
        NSString *readout = d ? [NSString stringWithFormat:@"ISO %.0f · %@ · f/%.1f\nEV %+.2f · Medidor %+.2f EV · Foco %.2f", d.ISO, shutter, d.lensAperture, d.exposureTargetBias, d.exposureTargetOffset, d.lensPosition] : @"Sem câmera ativa";
        dispatch_async(dispatch_get_main_queue(), ^{
            [self enableControls:ready];
            self.shutterButton.enabled = ready && settled;
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
    dispatch_async(self.sessionQueue, ^{
        if (!self.configured || !self.session.isRunning || self.captureBusy ||
            self.pendingExposure || self.pendingFocus || self.closing) return;
        NSError *error = nil;
        AVCapturePhotoSettings *settings = raw ? [self.controls rawSettingsForOutput:self.photoOutput error:&error] :
            [AVCapturePhotoSettings photoSettingsWithFormat:@{AVVideoCodecKey: AVVideoCodecTypeJPEG}];
        if (!settings) { [self message:error.localizedDescription]; return; }
        settings.photoQualityPrioritization = AVCapturePhotoQualityPrioritizationSpeed;
        settings.flashMode = AVCaptureFlashModeOff;
        if (!raw) settings.highResolutionPhotoEnabled = YES;
        self.captureBusy = YES; self.captureRAW = raw; self.captureID = settings.uniqueID;
        self.captureData = nil; self.captureError = nil; self.captureMetadata = nil;
        dispatch_async(dispatch_get_main_queue(), ^{ self.closeButton.enabled = NO; [self enableControls:NO]; });
        [self message:@"Capturando…"];
        [self.photoOutput capturePhotoWithSettings:settings delegate:self];
    });
}

- (void)photoOutput:(__unused AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    NSData *data = error ? nil : photo.fileDataRepresentation;
    int64_t captureID = photo.resolvedSettings.uniqueID;
    dispatch_async(self.sessionQueue, ^{
        if (captureID != self.captureID) return;
        self.captureData = data; self.captureError = error; self.captureMetadata = photo.metadata;
    });
}

- (void)photoOutput:(__unused AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)settings error:(NSError *)error {
    dispatch_async(self.sessionQueue, ^{
        if (settings.uniqueID != self.captureID) return;
        NSError *failure = error ?: self.captureError;
        NSURL *file = nil;
        if (!failure && self.captureData.length) {
            NSURL *directory = self.outputDirectory;
            if ([NSFileManager.defaultManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&failure]) {
                file = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"M7-%@.%@", NSUUID.UUID.UUIDString, self.captureRAW ? @"dng" : @"jpg"]];
                if (![self.captureData writeToURL:file options:NSDataWritingAtomic error:&failure]) file = nil;
                if (file && [NSJSONSerialization isValidJSONObject:self.captureMetadata]) {
                    NSData *metadata = [NSJSONSerialization dataWithJSONObject:self.captureMetadata options:NSJSONWritingPrettyPrinted error:nil];
                    [metadata writeToURL:[[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"json"] atomically:YES];
                }
            }
        }
        self.captureBusy = NO; self.captureData = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.closeButton.enabled = YES;
            if (file) { self.lastFile = file; self.shareButton.enabled = YES; }
        });
        if (!file) { [self message:failure.localizedDescription ?: @"A captura não retornou dados."]; return; }
        [self message:@"Arquivo salvo. Use Exportar para guardar no app Arquivos ou compartilhar."];
        // The system Camera may already have access. Never request access without
        // a host usage-description key; a tweak must not modify Camera.app's plist.
        PHAuthorizationStatus authorization = [PHPhotoLibrary authorizationStatusForAccessLevel:PHAccessLevelAddOnly];
        if (authorization == PHAuthorizationStatusAuthorized || authorization == PHAuthorizationStatusLimited) {
            [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                PHAssetCreationRequest *asset = [PHAssetCreationRequest creationRequestForAsset];
                PHAssetResourceCreationOptions *options = [PHAssetResourceCreationOptions new];
                options.originalFilename = file.lastPathComponent;
                [asset addResourceWithType:PHAssetResourceTypePhoto fileURL:file options:options];
            } completionHandler:^(BOOL success, NSError *saveError) {
                [self message:success ? @"Salvo no Fotos e disponível em Exportar." :
                    [NSString stringWithFormat:@"Arquivo preservado; Fotos: %@. Use Exportar.", saveError.localizedDescription ?: @"falha ao salvar"]];
            }];
        }
    });
}

- (void)share {
    NSArray<NSURL *> *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:self.outputDirectory
        includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    files = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = nil, *dateB = nil;
        [a getResourceValue:&dateA forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLContentModificationDateKey error:nil];
        return [dateB ?: NSDate.distantPast compare:dateA ?: NSDate.distantPast];
    }];
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:@"Exportar" message:@"Fotos recentes e diagnóstico" preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger count = 0;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateStyle = NSDateFormatterShortStyle; formatter.timeStyle = NSDateFormatterMediumStyle;
    for (NSURL *file in files) {
        if (![@[@"dng", @"jpg"] containsObject:file.pathExtension.lowercaseString] || count >= 12) continue;
        ++count;
        NSDate *date = nil; [file getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        NSString *title = [NSString stringWithFormat:@"%@ · %@", file.pathExtension.uppercaseString, [formatter stringFromDate:date ?: NSDate.date]];
        [menu addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            [self shareFile:file];
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Diagnóstico da lente" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        [self shareFile:[self.outputDirectory URLByAppendingPathComponent:@"diagnostico.json"]];
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancelar" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView = self.shareButton;
    [self presentViewController:menu animated:YES completion:nil];
}

- (void)shareFile:(NSURL *)file {
    if (![NSFileManager.defaultManager fileExistsAtPath:file.path]) { [self message:@"Arquivo indisponível."]; return; }
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[file] applicationActivities:nil];
    sheet.popoverPresentationController.sourceView = self.shareButton;
    [self presentViewController:sheet animated:YES completion:nil];
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
