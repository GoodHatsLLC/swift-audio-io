// © GoodHatsLLC

#import "AIOObjCException.h"

NSException *_Nullable AIOObjCExceptionRaisedBy(
    void (NS_NOESCAPE ^_Nonnull block)(void)) {
  @try {
    block();
  } @catch (NSException *exception) {
    return exception;
  }
  return nil;
}
