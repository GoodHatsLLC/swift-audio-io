// © GoodHatsLLC

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, returning the Objective-C exception it raised, or `nil` when
/// it completed normally.
///
/// Objective-C is the only language in this package that can catch an
/// `NSException`. AVFoundation's audio graph reports precondition violations
/// by raising one out of a C++ frame, and a raise that unwinds into Swift
/// aborts the process no matter what `do`/`catch` encloses the call.
///
/// The object that raised is left in an undefined state. A caller must treat a
/// non-nil result as a reason to tear that object down, never as a reason to
/// retry the same call in place.
NSException *_Nullable AIOObjCExceptionRaisedBy(
    void (NS_NOESCAPE ^_Nonnull block)(void));

NS_ASSUME_NONNULL_END
