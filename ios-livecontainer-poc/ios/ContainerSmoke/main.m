#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <ProbeKit/ProbeKit.h>

@interface SmokeViewController : UIViewController
@property(nonatomic, strong) UILabel *counter;
@property(nonatomic, strong) UILabel *cameraStatus;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) CFTimeInterval epoch;
@end

@implementation SmokeViewController
- (UILabel *)label:(NSString *)text {
    UILabel *label = [UILabel new];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    return label;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *ready = [self label:@"ContainerSmoke ready"];
    ready.font = [UIFont boldSystemFontOfSize:24];
    UILabel *framework = [self label:ProbeKitIdentity()];
    UILabel *identity = [self label:[NSString stringWithFormat:@"Bundle: %@\niOS reported: %@",
        NSBundle.mainBundle.bundleIdentifier ?: @"unknown", UIDevice.currentDevice.systemVersion]];
    self.counter = [self label:@"Display ticks: 0"];
    self.cameraStatus = [self label:@"Camera permission has not been requested."];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:@"Test camera permission" forState:UIControlStateNormal];
    [button addTarget:self action:@selector(testCamera) forControlEvents:UIControlEventTouchUpInside];
    UILabel *scope = [self label:@"Own test app. No video transmission yet.\nProbeKit is our embedded dynamic framework."];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[ready, framework, identity, self.counter, button, self.cameraStatus, scope]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:24],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:safe.bottomAnchor constant:-20]
    ]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.displayLink) return;
    self.epoch = CACurrentMediaTime();
    self.frames = 0;
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    [self.displayLink invalidate];
    self.displayLink = nil;
}
- (void)tick:(CADisplayLink *)link {
    self.frames += 1;
    if (self.frames % 30 != 0) return;
    self.counter.text = [NSString stringWithFormat:@"Display ticks: %lu\nElapsed: %.1f seconds",
        (unsigned long)self.frames, link.timestamp - self.epoch];
}
- (void)testCamera {
    __weak typeof(self) weakSelf = self;
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.cameraStatus.text = granted ? @"Camera permission granted; capture still untested." : @"Camera permission denied.";
        });
    }];
}
@end

@interface SmokeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation SmokeSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [SmokeViewController new];
    [self.window makeKeyAndVisible];
}
@end

@interface SmokeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation SmokeAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = SmokeSceneDelegate.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SmokeAppDelegate.class));
    }
}
