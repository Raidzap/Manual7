#import <Foundation/Foundation.h>

// Access on the controller's session queue. Both locations remain searchable
// after a fallback so that earlier captures never disappear from Exportar.
@interface M7Storage : NSObject
@property (nonatomic, readonly) NSURL *directory;
@property (nonatomic, readonly) NSArray<NSURL *> *candidates;
@property (nonatomic, readonly) NSArray<NSDictionary *> *attempts;
- (instancetype)initWithCandidates:(NSArray<NSURL *> *)candidates;
+ (NSArray<NSURL *> *)defaultCandidates;
- (BOOL)prepare:(NSError **)error;
- (NSArray<NSURL *> *)imageFilesWithError:(NSError **)error;
- (BOOL)writeJSON:(NSDictionary *)value filename:(NSString *)filename error:(NSError **)error;
@end
