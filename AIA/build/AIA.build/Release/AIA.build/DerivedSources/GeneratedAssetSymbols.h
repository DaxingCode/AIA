#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The "AIAvatar" asset catalog image resource.
static NSString * const ACImageNameAIAvatar AC_SWIFT_PRIVATE = @"AIAvatar";

/// The "AppLogo" asset catalog image resource.
static NSString * const ACImageNameAppLogo AC_SWIFT_PRIVATE = @"AppLogo";

/// The "wechat" asset catalog image resource.
static NSString * const ACImageNameWechat AC_SWIFT_PRIVATE = @"wechat";

#undef AC_SWIFT_PRIVATE
