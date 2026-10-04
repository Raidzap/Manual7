#import <Foundation/Foundation.h>

// Original (maxLongEdge == 0) returns the captured JPEG bytes unchanged.
// Smaller choices preserve aspect ratio, never upscale, normalize orientation,
// retain photographic metadata and encode JPEG at quality 0.95. Never use RAW.
NSData *M7JPEGForLongEdge(NSData *data, NSUInteger maxLongEdge, NSError **error);
NSDictionary *M7ImageProperties(NSData *data);
