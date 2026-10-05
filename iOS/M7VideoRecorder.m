#import "M7VideoRecorder.h"

static NSError *M7VideoRecorderError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Manual7.VideoRecorder" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

@interface M7VideoRecorder ()
@property (nonatomic) NSURL *outputURL;
@property (nonatomic) AVAssetWriter *writer;
@property (nonatomic) AVAssetWriterInput *videoInput;
@property (nonatomic) AVAssetWriterInput *audioInput;
@property (nonatomic) BOOL started;
@property (nonatomic) BOOL finished;
@property (nonatomic) CMTime startTime;
@property (nonatomic) NSUInteger videoFrames;
@property (nonatomic) NSUInteger audioSamples;
@property (nonatomic) NSUInteger droppedVideoFrames;
@property (nonatomic) NSUInteger backpressureVideoFrames;
@property (nonatomic) NSUInteger backpressureAudioSamples;
@property (nonatomic) int32_t width;
@property (nonatomic) int32_t height;
@property (nonatomic) Float64 nominalFrameRate;
@property (nonatomic) Float64 audioSampleRate;
@property (nonatomic) UInt32 audioChannels;
@property (nonatomic) NSError *terminalError;
@end

@implementation M7VideoRecorder

- (instancetype)initWithOutputURL:(NSURL *)url {
    if ((self = [super init])) {
        _outputURL = url;
        _startTime = kCMTimeInvalid;
    }
    return self;
}

- (NSError *)prepareWriterForVideoSample:(CMSampleBufferRef)sampleBuffer {
    CMFormatDescriptionRef description = CMSampleBufferGetFormatDescription(sampleBuffer);
    if (!description) return M7VideoRecorderError(1, @"O primeiro quadro não contém descrição de formato.");
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(description);
    if (dimensions.width < 2 || dimensions.height < 2)
        return M7VideoRecorderError(2, @"Dimensões inválidas no primeiro quadro de vídeo.");
    NSError *error = nil;
    [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:self.outputURL
        fileType:AVFileTypeQuickTimeMovie error:&error];
    if (!writer) return error ?: M7VideoRecorderError(3, @"Não foi possível criar o gravador de vídeo.");
    NSInteger pixels = (NSInteger)dimensions.width * dimensions.height;
    NSInteger bitRate = MAX(6000000, MIN(24000000, pixels * 6));
    NSDictionary *compression = @{AVVideoAverageBitRateKey:@(bitRate),
        AVVideoExpectedSourceFrameRateKey:@30,
        AVVideoMaxKeyFrameIntervalKey:@30,
        AVVideoProfileLevelKey:AVVideoProfileLevelH264HighAutoLevel};
    NSDictionary *videoSettings = @{AVVideoCodecKey:AVVideoCodecTypeH264,
        AVVideoWidthKey:@(dimensions.width), AVVideoHeightKey:@(dimensions.height),
        AVVideoCompressionPropertiesKey:compression};
    AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo
        outputSettings:videoSettings sourceFormatHint:description];
    video.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:video]) return M7VideoRecorderError(4, @"O gravador recusou a faixa de vídeo.");
    [writer addInput:video];

    Float64 sampleRate = self.audioSampleRate > 0 ? self.audioSampleRate : 48000;
    UInt32 channels = self.audioChannels > 0 && self.audioChannels <= 2 ? self.audioChannels : 1;
    NSDictionary *audioSettings = @{AVFormatIDKey:@(kAudioFormatMPEG4AAC),
        AVSampleRateKey:@(sampleRate), AVNumberOfChannelsKey:@(channels),
        AVEncoderBitRateKey:@(channels == 1 ? 96000 : 128000)};
    AVAssetWriterInput *audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio
        outputSettings:audioSettings];
    audio.expectsMediaDataInRealTime = YES;
    if ([writer canAddInput:audio]) [writer addInput:audio];
    else audio = nil;

    if (![writer startWriting]) return writer.error ?: M7VideoRecorderError(5, @"O gravador não iniciou.");
    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_VALID(timestamp)) return M7VideoRecorderError(6, @"O primeiro quadro não contém timestamp válido.");
    [writer startSessionAtSourceTime:timestamp];
    self.writer = writer;
    self.videoInput = video;
    self.audioInput = audio;
    self.width = dimensions.width;
    self.height = dimensions.height;
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
    self.nominalFrameRate = CMTIME_IS_NUMERIC(duration) && CMTimeGetSeconds(duration) > 0
        ? 1.0 / CMTimeGetSeconds(duration) : 0;
    self.startTime = timestamp;
    self.started = YES;
    return nil;
}

- (NSError *)appendSampleBuffer:(CMSampleBufferRef)sampleBuffer mediaType:(AVMediaType)mediaType {
    if (self.finished || self.terminalError) return self.terminalError;
    if (![mediaType isEqualToString:AVMediaTypeVideo] && ![mediaType isEqualToString:AVMediaTypeAudio]) return nil;
    if ([mediaType isEqualToString:AVMediaTypeAudio] && !self.started) {
        CMAudioFormatDescriptionRef format = CMSampleBufferGetFormatDescription(sampleBuffer);
        const AudioStreamBasicDescription *asbd = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
        if (asbd) { self.audioSampleRate = asbd->mSampleRate; self.audioChannels = asbd->mChannelsPerFrame; }
        return nil;
    }
    if ([mediaType isEqualToString:AVMediaTypeVideo] && !self.started) {
        NSError *error = [self prepareWriterForVideoSample:sampleBuffer];
        if (error) { self.terminalError = error; return error; }
    }
    if (!self.started) return nil; // Audio received before the first video frame.
    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_VALID(timestamp) && CMTimeCompare(timestamp, self.startTime) < 0) return nil;
    AVAssetWriterInput *input = [mediaType isEqualToString:AVMediaTypeVideo] ? self.videoInput : self.audioInput;
    if (!input) return nil;
    if (!input.readyForMoreMediaData) {
        if ([mediaType isEqualToString:AVMediaTypeVideo]) ++self.backpressureVideoFrames;
        else ++self.backpressureAudioSamples;
        return nil;
    }
    if (![input appendSampleBuffer:sampleBuffer]) {
        NSError *error = self.writer.error ?: M7VideoRecorderError(7, @"Falha ao anexar amostra ao vídeo.");
        self.terminalError = error;
        return error;
    }
    if ([mediaType isEqualToString:AVMediaTypeVideo]) ++self.videoFrames;
    else ++self.audioSamples;
    return nil;
}

- (void)noteDroppedVideoSample { ++self.droppedVideoFrames; }

- (NSTimeInterval)timeOffsetForSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!self.started || !CMTIME_IS_VALID(self.startTime)) return -1;
    CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (!CMTIME_IS_VALID(timestamp)) return -1;
    Float64 seconds = CMTimeGetSeconds(CMTimeSubtract(timestamp, self.startTime));
    return isfinite(seconds) && seconds >= 0 ? seconds : -1;
}

- (NSDictionary *)snapshot {
    return @{ @"started":@(self.started), @"finished":@(self.finished),
        @"writerStatus":@(self.writer.status), @"width":@(self.width), @"height":@(self.height),
        @"nominalFrameRate":@(self.nominalFrameRate), @"videoFrames":@(self.videoFrames),
        @"audioSamples":@(self.audioSamples), @"droppedVideoFrames":@(self.droppedVideoFrames),
        @"backpressureVideoFrames":@(self.backpressureVideoFrames),
        @"backpressureAudioSamples":@(self.backpressureAudioSamples),
        @"hasAudioInput":@(self.audioInput != nil), @"audioSampleRate":@(self.audioSampleRate),
        @"audioChannels":@(self.audioChannels), @"path":self.outputURL.path ?: @"" };
}

- (void)finishWithCompletion:(void (^)(NSURL *, NSDictionary *, NSError *))completion {
    if (self.finished) {
        completion(self.outputURL, [self snapshot], self.terminalError ?: M7VideoRecorderError(8, @"A gravação já foi encerrada."));
        return;
    }
    self.finished = YES;
    if (!self.started || !self.writer) {
        NSError *error = self.terminalError ?: M7VideoRecorderError(9, @"Nenhum quadro de vídeo foi recebido.");
        completion(self.outputURL, [self snapshot], error);
        return;
    }
    if (self.writer.status == AVAssetWriterStatusWriting) {
        [self.videoInput markAsFinished];
        [self.audioInput markAsFinished];
        [self.writer finishWritingWithCompletionHandler:^{
            NSError *error = self.writer.error ?: self.terminalError;
            completion(self.outputURL, [self snapshot], error);
        }];
    } else {
        NSError *error = self.writer.error ?: self.terminalError ?: M7VideoRecorderError(10, @"O gravador terminou em estado inválido.");
        completion(self.outputURL, [self snapshot], error);
    }
}

- (void)cancel {
    if (self.finished) return;
    self.finished = YES;
    [self.writer cancelWriting];
    [NSFileManager.defaultManager removeItemAtURL:self.outputURL error:nil];
}

@end
