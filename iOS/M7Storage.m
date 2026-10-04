#import "M7Storage.h"

@interface M7Storage ()
@property (nonatomic) NSURL *directory;
@property (nonatomic) NSArray<NSURL *> *candidates;
@property (nonatomic) NSArray<NSDictionary *> *attempts;
@end

@implementation M7Storage
+ (NSArray<NSURL *> *)defaultCandidates {
    NSMutableArray *urls = [NSMutableArray new];
    for (NSNumber *kind in @[@(NSDocumentDirectory), @(NSApplicationSupportDirectory)]) {
        NSURL *base = [NSFileManager.defaultManager URLsForDirectory:kind.unsignedIntegerValue
            inDomains:NSUserDomainMask].firstObject;
        if (base) [urls addObject:[base URLByAppendingPathComponent:@"Manual7" isDirectory:YES]];
    }
    return urls;
}
- (instancetype)initWithCandidates:(NSArray<NSURL *> *)candidates {
    if ((self = [super init])) { _candidates = [candidates copy]; _attempts = @[]; }
    return self;
}
- (BOOL)prepare:(NSError **)error {
    NSMutableArray *attempts = [NSMutableArray new];
    NSError *failure = nil;
    self.directory = nil;
    for (NSURL *candidate in self.candidates) {
        failure = nil;
        BOOL created = [NSFileManager.defaultManager createDirectoryAtURL:candidate
            withIntermediateDirectories:YES attributes:nil error:&failure];
        NSURL *probe = [candidate URLByAppendingPathComponent:[@".probe-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        BOOL writable = created && [[@"Manual7" dataUsingEncoding:NSUTF8StringEncoding]
            writeToURL:probe options:NSDataWritingAtomic error:&failure];
        if (writable) [NSFileManager.defaultManager removeItemAtURL:probe error:nil];
        [attempts addObject:@{@"path":candidate.path, @"writable":@(writable),
            @"domain":failure.domain ?: @"", @"code":@(failure.code),
            @"message":failure.localizedDescription ?: @""}];
        if (writable) { self.directory = candidate; break; }
    }
    self.attempts = attempts;
    if (!self.directory && error) *error = failure ?: [NSError errorWithDomain:@"Manual7.Storage" code:1
        userInfo:@{NSLocalizedDescriptionKey:@"Nenhuma pasta persistente disponível para gravar a foto."}];
    return self.directory != nil;
}
- (NSArray<NSURL *> *)imageFilesWithError:(NSError **)error {
    NSMutableArray *images = [NSMutableArray new];
    for (NSURL *candidate in self.candidates) {
        NSError *failure = nil;
        NSArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtURL:candidate
            includingPropertiesForKeys:@[NSURLContentModificationDateKey, NSURLIsRegularFileKey]
            options:NSDirectoryEnumerationSkipsHiddenFiles error:&failure];
        // Missing fallback folders are normal; access and read errors are not.
        if (failure && !([failure.domain isEqualToString:NSCocoaErrorDomain] && failure.code == NSFileReadNoSuchFileError)) {
            if (error) *error = failure;
        }
        for (NSURL *file in files) {
            NSNumber *regular = nil;
            [file getResourceValue:&regular forKey:NSURLIsRegularFileKey error:nil];
            if (regular.boolValue && [@[@"jpg", @"dng"] containsObject:file.pathExtension.lowercaseString]) [images addObject:file];
        }
    }
    return [images sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        NSDate *dateA = nil, *dateB = nil;
        [a getResourceValue:&dateA forKey:NSURLContentModificationDateKey error:nil];
        [b getResourceValue:&dateB forKey:NSURLContentModificationDateKey error:nil];
        return [dateB ?: NSDate.distantPast compare:dateA ?: NSDate.distantPast];
    }];
}
- (BOOL)writeJSON:(NSDictionary *)value filename:(NSString *)filename error:(NSError **)error {
    if (!self.directory) {
        if (error) *error = [NSError errorWithDomain:@"Manual7.Storage" code:2 userInfo:@{
            NSLocalizedDescriptionKey:@"Diagnóstico disponível na tela; pasta de gravação indisponível."}];
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:error];
    return data && [data writeToURL:[self.directory URLByAppendingPathComponent:filename] options:NSDataWritingAtomic error:error];
}
@end
