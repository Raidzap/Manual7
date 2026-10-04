#import "M7ErrorDetails.h"
#include <math.h>

static id M7ErrorValue(id value, NSUInteger depth) {
    if (!value) return NSNull.null;
    if (depth > 6) return @"[depth limit]";
    if ([value isKindOfClass:NSString.class])
        return [value length] > 4096 ? [[value substringToIndex:4096] stringByAppendingString:@"…"] : value;
    if ([value isKindOfClass:NSNumber.class]) return isfinite([value doubleValue]) ? value : [value description];
    if (value == NSNull.null) return value;
    if ([value isKindOfClass:NSError.class]) {
        NSError *error = value;
        return @{@"domain":error.domain ?: @"", @"code":@(error.code),
            @"message":M7ErrorValue(error.localizedDescription, depth + 1),
            @"failureReason":M7ErrorValue(error.localizedFailureReason, depth + 1),
            @"recoverySuggestion":M7ErrorValue(error.localizedRecoverySuggestion, depth + 1),
            @"userInfo":M7ErrorValue(error.userInfo, depth + 1)};
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary new];
        NSUInteger count = 0;
        for (id key in value) {
            if (count++ >= 32) { result[@"truncated"] = @YES; break; }
            result[M7ErrorValue([key description], depth + 1)] = M7ErrorValue(value[key], depth + 1);
        }
        return result;
    }
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray new];
        for (id item in value) {
            if (result.count >= 16) { [result addObject:@"[items truncated]"]; break; }
            [result addObject:M7ErrorValue(item, depth + 1)];
        }
        return result;
    }
    if ([value isKindOfClass:NSData.class]) return @{@"class":@"NSData", @"bytes":@([value length])};
    return M7ErrorValue([value description], depth + 1);
}

NSDictionary *M7ErrorDetails(NSError *error) { return error ? M7ErrorValue(error, 0) : @{}; }
