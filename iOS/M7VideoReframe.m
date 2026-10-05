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
    CGRect raw = CGRectMake(0, 0, naturalSize.width, naturalSize.height);
    CGRect oriented = CGRectApplyAffineTransform(raw, preferredTransform);
    CGFloat width = fabs(oriented.size.width), height = fabs(oriented.size.height);
    if (width <= 0 || height <= 0 || renderSize.width <= 0 || renderSize.height <= 0)
        return CGAffineTransformIdentity;
    CGAffineTransform transform = CGAffineTransformConcat(preferredTransform,
        CGAffineTransformMakeTranslation(-CGRectGetMinX(oriented), -CGRectGetMinY(oriented)));
    CGFloat scale = MAX(renderSize.width / width, renderSize.height / height);
    transform = CGAffineTransformConcat(transform, CGAffineTransformMakeScale(scale, scale));
    CGFloat x = (renderSize.width - width * scale) / 2.0;
    CGFloat y = (renderSize.height - height * scale) / 2.0;
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
    CGAffineTransform transform = M7AspectFillVideoTransform(track.naturalSize, track.preferredTransform, target);
    [layer setTransform:transform atTime:kCMTimeZero];
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
        NSError *error = exporter.status == AVAssetExportSessionStatusCompleted ? nil :
            exporter.error ?: M7ReframeError(4, @"A exportação não terminou.");
        completion(details, error);
    }];
}
