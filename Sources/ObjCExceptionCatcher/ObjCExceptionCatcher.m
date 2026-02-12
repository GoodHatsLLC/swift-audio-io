#import "ObjCExceptionCatcher.h"

BOOL AIORunCatchingObjCException(void (NS_NOESCAPE ^_Nonnull block)(void),
                                 NSException *_Nullable *_Nullable outException) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (outException) {
            *outException = exception;
        }
        return NO;
    }
}
