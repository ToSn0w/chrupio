#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OKObjC : NSObject
/// Runs `block` and turns an Objective-C exception into an error. Swift can't catch exceptions, and AppKit catching
/// one after it unwound through Swift frames leaves locks held and tasks corrupted (crash of 2026-10-20 14:47).
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
