#import "ProbeKit.h"
NSString *ProbeKitIdentity(void) {
    return [NSString stringWithFormat:@"ProbeKit loaded: %@", [NSBundle bundleForClass:NSClassFromString(@"ProbeMarker")].bundleIdentifier ?: @"unknown"];
}
@interface ProbeMarker : NSObject @end
@implementation ProbeMarker @end
__attribute__((constructor)) static void ProbeLoaded(void) {
    NSLog(@"[ProbeKit] signed dynamic framework constructor ran in own test app");
}
