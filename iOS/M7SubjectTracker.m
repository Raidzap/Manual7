#import "M7SubjectTracker.h"
#import <Vision/Vision.h>
#import <ImageIO/CGImageProperties.h>
#include <float.h>
#include <math.h>

@interface M7SubjectTracker ()
@property (nonatomic) CGPoint center;
@property (nonatomic) NSMutableArray<NSDictionary *> *points;
@property (nonatomic) NSUInteger analyses;
@property (nonatomic) NSUInteger detections;
@property (nonatomic) NSUInteger misses;
@property (nonatomic) NSUInteger consecutiveMisses;
@property (nonatomic) NSString *lastKind;
@property (nonatomic) NSError *lastError;
@property (nonatomic) CGFloat lastConfidence;
@property (nonatomic) NSUInteger lastCandidateCount;
@property (nonatomic) size_t pixelWidth;
@property (nonatomic) size_t pixelHeight;
@property (nonatomic) OSType pixelFormat;
@end

@implementation M7SubjectTracker

- (instancetype)init {
    if ((self = [super init])) [self reset];
    return self;
}

- (void)reset {
    self.center = CGPointMake(.5, .5);
    self.points = [NSMutableArray new];
    self.analyses = 0; self.detections = 0; self.misses = 0; self.consecutiveMisses = 0;
    self.lastKind = @"none"; self.lastError = nil;
    self.lastConfidence = 0; self.lastCandidateCount = 0;
    self.pixelWidth = 0; self.pixelHeight = 0; self.pixelFormat = 0;
}

static CGFloat M7ClampUnit(CGFloat value) { return MIN(1.0, MAX(0.0, value)); }

- (NSDictionary *)analyzePixelBuffer:(CVPixelBufferRef)pixelBuffer
                          timeOffset:(NSTimeInterval)timeOffset
                              record:(BOOL)record {
    ++self.analyses;
    self.pixelWidth = CVPixelBufferGetWidth(pixelBuffer);
    self.pixelHeight = CVPixelBufferGetHeight(pixelBuffer);
    self.pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
    VNDetectHumanRectanglesRequest *humans = [VNDetectHumanRectanglesRequest new];
    humans.upperBodyOnly = YES;
    VNDetectFaceRectanglesRequest *faces = [VNDetectFaceRectanglesRequest new];
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer
        orientation:kCGImagePropertyOrientationUp options:@{}];
    NSError *error = nil;
    BOOL performed = [handler performRequests:@[humans, faces] error:&error];
    self.lastError = error;
    NSArray<VNDetectedObjectObservation *> *observations =
        (NSArray<VNDetectedObjectObservation *> *)humans.results;
    NSUInteger humanCount = observations.count;
    NSUInteger faceCount = faces.results.count;
    NSString *kind = @"person";
    if (!observations.count) {
        observations = (NSArray<VNDetectedObjectObservation *> *)faces.results;
        kind = @"face";
    }
    VNDetectedObjectObservation *best = nil;
    double bestScore = -DBL_MAX;
    for (VNDetectedObjectObservation *observation in observations) {
        CGRect box = observation.boundingBox;
        CGPoint candidate = CGPointMake(CGRectGetMidX(box), 1.0-CGRectGetMidY(box));
        double dx = candidate.x-self.center.x, dy = candidate.y-self.center.y;
        double area = box.size.width*box.size.height;
        double score = area - sqrt(dx*dx+dy*dy)*.12;
        if (score > bestScore) { bestScore = score; best = observation; }
    }
    BOOL detected = performed && best != nil;
    CGFloat confidence = detected ? best.confidence : 0;
    self.lastConfidence = confidence;
    self.lastCandidateCount = observations.count;
    if (detected) {
        ++self.detections; self.consecutiveMisses = 0; self.lastKind = kind;
        CGPoint measured = CGPointMake(CGRectGetMidX(best.boundingBox), 1.0-CGRectGetMidY(best.boundingBox));
        CGFloat dx = MAX(-.10, MIN(.10, measured.x-self.center.x));
        CGFloat dy = MAX(-.10, MIN(.10, measured.y-self.center.y));
        self.center = CGPointMake(M7ClampUnit(self.center.x + dx*.38),
            M7ClampUnit(self.center.y + dy*.38));
    } else {
        ++self.misses; ++self.consecutiveMisses; self.lastKind = @"lost";
        if (self.consecutiveMisses >= 5) {
            self.center = CGPointMake(self.center.x*.92 + .5*.08, self.center.y*.92 + .5*.08);
        }
    }
    NSMutableDictionary *result = [@{@"performed":@(performed), @"detected":@(detected),
        @"kind":self.lastKind ?: @"none", @"confidence":@(confidence),
        @"centerX":@(self.center.x), @"centerY":@(self.center.y),
        @"humanCandidates":@(humanCount), @"faceCandidates":@(faceCount),
        @"selectedCandidates":@(observations.count),
        @"consecutiveMisses":@(self.consecutiveMisses),
        @"time":@(timeOffset >= 0 && isfinite(timeOffset) ? timeOffset : -1)} mutableCopy];
    result[@"boundingBoxVision"] = detected ? @{ @"x":@(best.boundingBox.origin.x),
        @"y":@(best.boundingBox.origin.y), @"width":@(best.boundingBox.size.width),
        @"height":@(best.boundingBox.size.height) } : @{};
    if (error) result[@"error"] = @{@"domain":error.domain ?: @"", @"code":@(error.code),
        @"message":error.localizedDescription ?: @""};
    if (record && timeOffset >= 0 && isfinite(timeOffset)) {
        [self.points addObject:[result copy]];
    }
    return result;
}

- (NSArray<NSDictionary *> *)trackingPoints { return [self.points copy]; }

- (NSDictionary *)snapshot {
    return @{@"centerX":@(self.center.x), @"centerY":@(self.center.y),
        @"analyses":@(self.analyses), @"detections":@(self.detections),
        @"misses":@(self.misses), @"consecutiveMisses":@(self.consecutiveMisses),
        @"lastKind":self.lastKind ?: @"none", @"pointCount":@(self.points.count),
        @"lastConfidence":@(self.lastConfidence), @"lastCandidateCount":@(self.lastCandidateCount),
        @"pixelWidth":@(self.pixelWidth), @"pixelHeight":@(self.pixelHeight),
        @"pixelFormat":@(self.pixelFormat), @"orientation":@"up",
        @"lastError":self.lastError ? @{@"domain":self.lastError.domain ?: @"",
            @"code":@(self.lastError.code), @"message":self.lastError.localizedDescription ?: @""} : @{}};
}

@end
