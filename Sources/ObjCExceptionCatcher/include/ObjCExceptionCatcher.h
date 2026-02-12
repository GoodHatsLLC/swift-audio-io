#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Executes a block, catching any Objective-C exception that it throws.
///
/// @param block The block to execute.
/// @param outException On return, contains the caught NSException (if any).
/// @return YES if the block completed without throwing; NO if an exception was caught.
BOOL AIORunCatchingObjCException(void (NS_NOESCAPE ^_Nonnull block)(void),
                                 NSException *_Nullable *_Nullable outException);

NS_ASSUME_NONNULL_END
