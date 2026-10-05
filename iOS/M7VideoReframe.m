#import "M7VideoReframe.h"

static NSError *M7ReframeError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"Manual7.VideoReframe" code:code
        userInfo:@{NSLocalizedDescriptionKey:message}];
}

CGSize M7VideoFrameSize(M7VideoFrame frame) {
    return frame == M7VideoFrameVertical ? CGSizeMake(1080, 1920) : CGSizeMake(1920, 1080);
}

CGAffineTransform M7AspectFillVideoTransform(CGSize naturalSize,
    CGAffineTransform preferredTransform, CGSize renderSize) {
    return M7AspectFillVideoTransformAtPoint(naturalSize, preferredTransform, renderSize,
        CGPointMake(.5, .5));
}

static CGFloat M7Clamp(CGFloat value, CGFloat lower, CGFloat upper) {
    return MIN(upper, MAX(lower, value));
}

CGAffineTransform M7AspectFillVideoTransformAtPoint(CGSize naturalSize,
    CGAffineTransform preferredTransform, CGSize renderSize, CGPoint normalizedCenter) {
    CGRect raw = CGRectMake(0, 0, naturalSize.width, naturalSize.height);
    CGRect oriented = CGRectApplyAffineTransform(raw, preferredTransform);
    CGFloat width = fabs(oriented.size.width), height = fabs(oriented.size.height);
    if (width <= 0 || height <= 0 || renderSize.width <= 0 || renderSize.height <= 0)
        return CGAffineTransformIdentity;
    CGAffineTransform transform = CGAffineTransformConcat(preferredTransform,
        CGAffineTransformMakeTranslation(-CGRectGetMinX(oriented), -CGRectGetMinY(oriented)));
    CGFloat scale = MAX(renderSize.width / width, renderSize.height / height);
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));
    CGFloat centerX = M7Clamp(normalizedCenter.x, 0, 1) * width * scale;
    CGFloat centerY = M7Clamp(normalizedCenter.y, 0, 1) * height * scale;
    CGFloat x = M7Clamp(renderSize.width/2.0-centerX, renderSize.width-width*scale, 0);
    CGFloat y = M7Clamp(renderSize.height/2.0-centerY, renderSize.height-height*scale, 0);
    return CGAffineTransformConcat(transform, CGAffineTransformMakeTranslation(x, y));
}

NSDictionary *M7VideoFileDetails(NSURL *url) {
    NSNumber *bytes = nil;
    NSDate *date = nil;
    [url getResourceValue:&bytes forKey:NSURLFileSizeKey error:nil];
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audio = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    CGRect displayed = video ? CGRectApplyAffineTransform((CGRect){CGPointZero, video.naturalSize}, video.preferredTransform) : CGRectZero;
    Float64 duration = CMTimeGetSeconds(asset.duration);
    return @{ @"path":url.path ?: @"", @"exists":@([NSFileManager.defaultManager fileExistsAtPath:url.path]),
        @"bytes":bytes ?: @0, @"modified":date ? @(date.timeIntervalSince1970) : @0,
        @"duration":@(isfinite(duration) ? duration : 0), @"videoTracks":@([asset tracksWithMediaType:AVMediaTypeVideo].count),
        @"audioTracks":@([asset tracksWithMediaType:AVMediaTypeAudio].count),
        @"encodedWidth":@(video.naturalSize.width), @"encodedHeight":@(video.naturalSize.height),
        @"displayWidth":@(fabs(displayed.size.width)), @"displayHeight":@(fabs(displayed.size.height)),
        @"nominalFrameRate":@(video.nominalFrameRate), @"estimatedDataRate":@(video.estimatedDataRate),
        @"audioSampleRate":@(audio.naturalTimeScale) };
}

void M7ExportVideoFrame(NSURL *sourceURL, NSURL *outputURL, M7VideoFrame frame,
    void (^completion)(NSDictionary *, NSError *)) {
    M7ExportTrackedVideoFrame(sourceURL, outputURL, frame, @[], completion);
}

static NSArray<NSDictionary *> *M7UsableTrackingPoints(NSArray<NSDictionary *> *points,
    NSTimeInterval duration) {
    NSMutableArray<NSDictionary *> *usable = [NSMutableArray new];
    NSTimeInterval previous = -1;
    for (NSDictionary *point in points) {
        double time = [point[@"time"] doubleValue];
        double x = [point[@"centerX"] doubleValue], y = [point[@"centerY"] doubleValue];
        if (!isfinite(time) || !isfinite(x) || !isfinite(y) || time < 0 || time > duration) continue;
        if (time <= previous + .001) continue;
        [usable addObject:@{@"time":@(time), @"centerX":@(M7Clamp(x, 0, 1)),
            @"centerY":@(M7Clamp(y, 0, 1))}];
        previous = time;
    }
    return usable;
}

void M7ExportTrackedVideoFrame(NSURL *sourceURL, NSURL *outputURL, M7VideoFrame frame,
    NSArray<NSDictionary *> *trackingPoints, void (^completion)(NSDictionary *, NSError *)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:sourceURL options:@{AVURLAssetPreferPreciseDurationAndTimingKey:@YES}];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) { completion(@{}, M7ReframeError(1, @"O master não contém faixa de vídeo.")); return; }
    CGSize target = M7VideoFrameSize(frame);
    if (track.naturalSize.width <= 0 || track.naturalSize.height <= 0 || !CMTIME_IS_NUMERIC(asset.duration)) {
        completion(@{}, M7ReframeError(2, @"Geometria ou duração inválida no master.")); return;
    }
    AVMutableVideoComposition *composition = [AVMutableVideoComposition videoComposition];
    composition.renderSize = target;
    composition.frameDuration = CMTimeMake(1, 30);
    AVMutableVideoCompositionInstruction *instruction = [AVMutableVideoCompositionInstruction videoCompositionInstruction];
    instruction.timeRange = CMTimeRangeMake(kCMTimeZero, asset.duration);
    AVMutableVideoCompositionLayerInstruction *layer = [AVMutableVideoCompositionLayerInstruction
        videoCompositionLayerInstructionWithAssetTrack:track];
    NSTimeInterval duration = CMTimeGetSeconds(asset.duration);
    NSArray<NSDictionary *> *usable = M7UsableTrackingPoints(trackingPoints, duration);
    if (!usable.count) {
        [layer setTransform:M7AspectFillVideoTransform(track.naturalSize,
            track.preferredTransform, target) atTime:kCMTimeZero];
    } else {
        NSDictionary *first = usable.firstObject;
        CGPoint firstCenter = CGPointMake([first[@"centerX"] doubleValue], [first[@"centerY"] doubleValue]);
        CGAffineTransform firstTransform = M7AspectFillVideoTransformAtPoint(track.naturalSize,
            track.preferredTransform, target, firstCenter);
        [layer setTransform:firstTransform atTime:kCMTimeZero];
        NSDictionary *previous = first;
        CGAffineTransform previousTransform = firstTransform;
        for (NSUInteger index = 1; index < usable.count; ++index) {
            NSDictionary *point = usable[index];
            CMTime start = CMTimeMakeWithSeconds([previous[@"time"] doubleValue], 600);
            CMTime end = CMTimeMakeWithSeconds([point[@"time"] doubleValue], 600);
            CMTime span = CMTimeSubtract(end, start);
            CGPoint center = CGPointMake([point[@"centerX"] doubleValue], [point[@"centerY"] doubleValue]);
            CGAffineTransform nextTransform = M7AspectFillVideoTransformAtPoint(track.naturalSize,
                track.preferredTransform, target, center);
            if (CMTimeCompare(span, kCMTimeZero) > 0) {
                [layer setTransformRampFromStartTransform:previousTransform toEndTransform:nextTransform
                    timeRange:CMTimeRangeMake(start, span)];
            }
            previous = point;
            previousTransform = nextTransform;
        }
        [layer setTransform:previousTransform
            atTime:CMTimeMakeWithSeconds([previous[@"time"] doubleValue], 600)];
    }
    instruction.layerInstructions = @[layer];
    composition.instructions = @[instruction];

    [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
    AVAssetExportSession *exporter = [[AVAssetExportSession alloc] initWithAsset:asset
        presetName:AVAssetExportPresetHighestQuality];
    if (!exporter) { completion(@{}, M7ReframeError(3, @"O iOS recusou a sessão de exportação.")); return; }
    exporter.outputURL = outputURL;
    exporter.outputFileType = AVFileTypeMPEG4;
    exporter.shouldOptimizeForNetworkUse = YES;
    exporter.videoComposition = composition;
    [exporter exportAsynchronouslyWithCompletionHandler:^{
        NSMutableDictionary *details = [M7VideoFileDetails(outputURL) mutableCopy];
        details[@"exportStatus"] = @(exporter.status);
        details[@"frame"] = frame == M7VideoFrameVertical ? @"vertical9x16" : @"horizontal16x9";
        details[@"renderWidth"] = @(target.width);
        details[@"renderHeight"] = @(target.height);
        details[@"trackingPointCount"] = @(usable.count);
        details[@"dynamicReframe"] = @(usable.count > 0);
        NSError *error = exporter.status == AVAssetExportSessionStatusCompleted ? nil :
            exporter.error ?: M7ReframeError(4, @"A exportação não terminou.");
        completion(details, error);
    }];
}
