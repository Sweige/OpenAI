// External LiveContainer tweak, deliberately restricted to our own laboratory App.
// There is no cross-process camera provider and no third-party bundle allowlist.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "NetworkSource.h"

typedef NS_ENUM(NSInteger, OBCLMode) { OBCLModeOff,OBCLModePattern,OBCLModeOBS };
static const char kProxyKey;
static void (*originalSetter)(id,SEL,id,dispatch_queue_t);

@interface OBCLHookState : NSObject
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) OBCLNetworkSource *network;
@property(nonatomic) OBCLMode mode;
@property(nonatomic) uint64_t calls,replaced,dropped,wrapped;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UILabel *label;
@property(nonatomic,strong) UITextField *host;
@property(nonatomic,strong) UISegmentedControl *selector;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic) BOOL collapsed;
+ (instancetype)shared;
- (void)installPanel;
@end

@interface OBCLDelegateProxy : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic,weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> target;
@end

@implementation OBCLDelegateProxy {
    CVPixelBufferPoolRef _pool;
    size_t _width,_height;
    uint64_t _patternIndex;
}
- (void)dealloc {
    if (_pool) CFRelease(_pool);
}
- (CVPixelBufferRef)newPatternForReference:(CVPixelBufferRef)reference CF_RETURNS_RETAINED {
    size_t w=CVPixelBufferGetWidth(reference), h=CVPixelBufferGetHeight(reference);
    if (!w || !h || (w&1) || (h&1) || w>4096 || h>4096) return NULL;
    if (!_pool || w!=_width || h!=_height) {
        if (_pool) CFRelease(_pool); _pool=NULL;
        _width=w; _height=h;
        NSDictionary *attrs=@{(__bridge NSString *)kCVPixelBufferWidthKey:@(w),(__bridge NSString *)kCVPixelBufferHeightKey:@(h),
            (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            (__bridge NSString *)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault,NULL,(__bridge CFDictionaryRef)attrs,&_pool)) return NULL;
    }
    NSDictionary *limit=@{(__bridge NSString *)kCVPixelBufferPoolAllocationThresholdKey:@4}; CVPixelBufferRef pixel=NULL;
    if (CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,_pool,(__bridge CFDictionaryRef)limit,&pixel)) return NULL;
    if (CVPixelBufferLockBaseAddress(pixel,0)) { CVPixelBufferRelease(pixel); return NULL; }
    uint8_t *y=CVPixelBufferGetBaseAddressOfPlane(pixel,0), *uv=CVPixelBufferGetBaseAddressOfPlane(pixel,1);
    size_t ys=CVPixelBufferGetBytesPerRowOfPlane(pixel,0), cs=CVPixelBufferGetBytesPerRowOfPlane(pixel,1);
    // Seven fixed luma columns distinguish this source from OBS / real camera.
    const uint8_t bars[7]={32,64,96,128,160,192,224};
    memset(y,16,ys*h); memset(uv,128,cs*(h/2));
    for (size_t row=0;row<h;row++) for (size_t b=0;b<7;b++) {
        size_t x0=w*b/7,x1=w*(b+1)/7; memset(y+row*ys+x0,bars[b],x1-x0);
    }
    size_t band=(size_t)((_patternIndex*11)%(h-h/32));
    for (size_t row=band;row<MIN(h,band+MAX((size_t)2,h/32));row++) memset(y+row*ys,235,w);
    // Bottom binary stamp: first cell is always bright, followed by frame-counter bits.
    for (size_t cell=0;cell<17;cell++) {
        uint8_t value=(cell==0 || ((_patternIndex>>(cell-1))&1)) ? 235:16;
        size_t x0=w*cell/17,x1=w*(cell+1)/17;
        for (size_t row=h*7/8;row<h*15/16;row++) memset(y+row*ys+x0,value,x1-x0);
    }
    _patternIndex++;
    CVPixelBufferUnlockBaseAddress(pixel,0);
    CVBufferSetAttachment(pixel,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(pixel,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
    return pixel;
}
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    OBCLHookState *state=[OBCLHookState shared];
    [state.lock lock]; state.calls++; OBCLMode mode=state.mode; [state.lock unlock];
    id<AVCaptureVideoDataOutputSampleBufferDelegate> target=self.target;
    if (!target) return;
    if (mode==OBCLModeOff) { [target captureOutput:output didOutputSampleBuffer:sample fromConnection:connection]; return; }
    CVPixelBufferRef reference=CMSampleBufferGetImageBuffer(sample);
    CVPixelBufferRef pixel=mode==OBCLModePattern && reference ? [self newPatternForReference:reference] :
        (mode==OBCLModeOBS ? [state.network copyLatestWithMaximumAge:0.5] : NULL);
    if (!pixel) { [state.lock lock]; state.dropped++; [state.lock unlock]; return; }
    CMVideoFormatDescriptionRef format=NULL; CMSampleBufferRef replacement=NULL;
    CMSampleTimingInfo timing={CMSampleBufferGetDuration(sample),CMSampleBufferGetPresentationTimeStamp(sample),kCMTimeInvalid};
    OSStatus e=CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault,pixel,&format);
    if (!e) e=CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault,pixel,format,&timing,&replacement);
    if (!e) {
        [target captureOutput:output didOutputSampleBuffer:replacement fromConnection:connection];
        [state.lock lock]; state.replaced++; [state.lock unlock];
    } else { [state.lock lock]; state.dropped++; [state.lock unlock]; }
    if (replacement) CFRelease(replacement); if (format) CFRelease(format); CVPixelBufferRelease(pixel);
}
- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection {
    id target=self.target;
    if ([target respondsToSelector:_cmd]) [target captureOutput:output didDropSampleBuffer:sample fromConnection:connection];
}
@end

static void hookedSetter(id output,SEL selector,id delegate,dispatch_queue_t queue) {
    if (delegate && [NSStringFromClass([delegate class]) isEqualToString:@"OBSiPhoneLab.Camera"]) {
        OBCLDelegateProxy *proxy=[OBCLDelegateProxy new]; proxy.target=delegate;
        objc_setAssociatedObject(output,&kProxyKey,proxy,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        OBCLHookState *state=[OBCLHookState shared]; [state.lock lock]; state.wrapped++; [state.lock unlock];
        originalSetter(output,selector,proxy,queue);
        NSLog(@"[OBSCaptureHook] wrapped own delegate OBSiPhoneLab.Camera");
    } else {
        originalSetter(output,selector,delegate,queue);
        objc_setAssociatedObject(output,&kProxyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@implementation OBCLHookState
+ (instancetype)shared {
    static OBCLHookState *state; static dispatch_once_t once;
    dispatch_once(&once,^{ state=[self new]; state.lock=[NSLock new]; state.network=[OBCLNetworkSource new]; state.mode=OBCLModeOff; });
    return state;
}
- (void)modeChanged {
    [self.lock lock]; self.mode=(OBCLMode)self.selector.selectedSegmentIndex; [self.lock unlock];
    if (self.selector.selectedSegmentIndex!=OBCLModeOBS) [self.network stop];
}
- (void)connect {
    [self.panel endEditing:YES];
    self.selector.selectedSegmentIndex=OBCLModeOBS;
    [self.lock lock]; self.mode=OBCLModeOBS; [self.lock unlock];
    [self.network startHost:[self.host.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] port:9002];
}
- (void)background {
    [self.network stop]; [self.lock lock]; self.mode=OBCLModeOff; [self.lock unlock];
    self.selector.selectedSegmentIndex=OBCLModeOff;
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    CGPoint delta=[gesture translationInView:self.panel.superview];
    CGPoint center=self.panel.center; center.x+=delta.x; center.y+=delta.y;
    CGRect bounds=self.panel.superview.bounds;
    center.x=MAX(self.panel.bounds.size.width/2,MIN(bounds.size.width-self.panel.bounds.size.width/2,center.x));
    center.y=MAX(self.panel.bounds.size.height/2+40,MIN(bounds.size.height-self.panel.bounds.size.height/2-15,center.y));
    self.panel.center=center; [gesture setTranslation:CGPointZero inView:self.panel.superview];
}
- (void)collapse {
    self.collapsed=!self.collapsed;
    for (UIView *view in self.panel.subviews) if (view.tag!=1) view.hidden=self.collapsed;
    CGRect frame=self.panel.frame; frame.size.height=self.collapsed?28:181; self.panel.frame=frame;
}
- (void)installPanel {
    if (self.panel) return;
    UIWindow *window=nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) if (candidate.isKeyWindow) { window=candidate; break; }
    }
    if (!window) return;
    CGFloat width=MIN((CGFloat)262,window.bounds.size.width-24);
    self.panel=[[UIView alloc] initWithFrame:CGRectMake(window.bounds.size.width-width-12,window.bounds.size.height-210,width,181)];
    self.panel.backgroundColor=[UIColor colorWithWhite:0.12 alpha:0.94]; self.panel.layer.cornerRadius=9;
    UILabel *header=[[UILabel alloc] initWithFrame:CGRectMake(8,0,width-42,28)];
    header.tag=1; header.text=@"VCAM Lab · external dylib"; header.textColor=UIColor.whiteColor;
    header.font=[UIFont boldSystemFontOfSize:12]; header.userInteractionEnabled=YES;
    [header addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.panel addSubview:header];
    UIButton *collapse=[UIButton buttonWithType:UIButtonTypeSystem]; collapse.tag=1;
    collapse.frame=CGRectMake(width-32,0,28,28); [collapse setTitle:@"±" forState:UIControlStateNormal];
    [collapse addTarget:self action:@selector(collapse) forControlEvents:UIControlEventTouchUpInside]; [self.panel addSubview:collapse];
    self.selector=[[UISegmentedControl alloc] initWithItems:@[@"Off",@"Pattern",@"OBS"]];
    self.selector.frame=CGRectMake(8,30,width-16,28); self.selector.selectedSegmentIndex=0;
    self.selector.backgroundColor=UIColor.systemGrayColor;
    [self.selector addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged]; [self.panel addSubview:self.selector];
    self.host=[[UITextField alloc] initWithFrame:CGRectMake(8,64,width-110,28)];
    self.host.text=@"192.168.50.39"; self.host.font=[UIFont systemFontOfSize:12]; self.host.borderStyle=UITextBorderStyleRoundedRect;
    self.host.keyboardType=UIKeyboardTypeNumbersAndPunctuation; self.host.autocorrectionType=UITextAutocorrectionTypeNo;
    [self.panel addSubview:self.host];
    UIButton *connect=[UIButton buttonWithType:UIButtonTypeSystem]; connect.frame=CGRectMake(width-100,64,94,28);
    [connect setTitle:@"OBS :9002" forState:UIControlStateNormal]; connect.titleLabel.font=[UIFont systemFontOfSize:12];
    [connect addTarget:self action:@selector(connect) forControlEvents:UIControlEventTouchUpInside]; [self.panel addSubview:connect];
    self.label=[[UILabel alloc] initWithFrame:CGRectMake(8,97,width-16,80)]; self.label.textColor=UIColor.whiteColor;
    self.label.font=[UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular]; self.label.numberOfLines=5;
    [self.panel addSubview:self.label]; [window addSubview:self.panel];
}
- (void)tick {
    if (!self.panel) [self installPanel];
    [self.lock lock];
    NSString *stats=[NSString stringWithFormat:@"wrapped %llu · callbacks %llu\nreplaced %llu · dropped %llu",(unsigned long long)self.wrapped,
        (unsigned long long)self.calls,(unsigned long long)self.replaced,(unsigned long long)self.dropped];
    [self.lock unlock]; self.label.text=[NSString stringWithFormat:@"%@\n%@",stats,[self.network status]];
    if (self.panel) [self.panel.superview bringSubviewToFront:self.panel];
}
@end

__attribute__((constructor)) static void OBCLInstall(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.example.OBSiPhoneLab"]) return;
        Method method=class_getInstanceMethod(AVCaptureVideoDataOutput.class,@selector(setSampleBufferDelegate:queue:));
        if (!method) return;
        originalSetter=(void (*)(id,SEL,id,dispatch_queue_t))method_setImplementation(method,(IMP)hookedSetter);
        NSLog(@"[OBSCaptureHook] external dylib loaded; restricted to com.example.OBSiPhoneLab");
        dispatch_async(dispatch_get_main_queue(),^{
            OBCLHookState *state=[OBCLHookState shared];
            [NSNotificationCenter.defaultCenter addObserver:state selector:@selector(background) name:UIApplicationDidEnterBackgroundNotification object:nil];
            state.timer=[NSTimer scheduledTimerWithTimeInterval:0.5 target:state selector:@selector(tick) userInfo:nil repeats:YES];
        });
    }
}
