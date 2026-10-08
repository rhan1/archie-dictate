#import "DictateObjC.h"
BOOL DictateTryObjC(void (NS_NOESCAPE ^block)(void), NSError **error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"DictateObjC" code:1 userInfo:@{
                @"name": exception.name,
                @"reason": exception.reason ?: @"",
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""]
            }];
        }
        return NO;
    }
}
