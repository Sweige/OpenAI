#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
// OBSC/1, video-only, own laboratory receiver. Latest-frame storage is bounded.
@interface OBCLNetworkSource : NSObject
- (void)startHost:(NSString *)host port:(uint16_t)port;
- (void)stop;
- (nullable CVPixelBufferRef)copyLatestWithMaximumAge:(double)age CF_RETURNS_RETAINED;
- (NSString *)status;
@end
NS_ASSUME_NONNULL_END
