import UIKit
import AVFoundation
import ProbeKit

final class SampleView:UIView {
    override class var layerClass:AnyClass { AVSampleBufferDisplayLayer.self }
    private var display:AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private let lock=NSLock()
    private var latest:CMSampleBuffer?
    private var scheduled=false
    override init(frame:CGRect) {
        super.init(frame:frame); display.videoGravity = .resizeAspect; backgroundColor = .black
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is unused") }
    // One pending main-queue task and one latest frame: UI stalls cannot create an unbounded queue.
    func submit(_ sample:CMSampleBuffer) {
        lock.lock(); latest=sample
        if scheduled { lock.unlock(); return }
        scheduled=true; lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self=self else { return }
            self.lock.lock(); let s=self.latest; self.latest=nil; self.scheduled=false; self.lock.unlock()
            guard let s=s else { return }
            if self.display.status == .failed { self.display.flush() }
            if let array=CMSampleBufferGetSampleAttachmentsArray(s,createIfNecessary:true), CFArrayGetCount(array)>0 {
                let dict=unsafeBitCast(CFArrayGetValueAtIndex(array,0),to:CFMutableDictionary.self)
                CFDictionarySetValue(dict,Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            if self.display.isReadyForMoreMediaData { self.display.enqueue(s) }
        }
    }
}

final class ViewController:UIViewController {
    private let pipeline=Pipeline()
    private let preview=SampleView()
    private let host=UITextField()
    private let status=UILabel()
    private let resolution=UISegmentedControl(items:["720×1280","1080×1920"])
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground
        UIApplication.shared.isIdleTimerDisabled=true
        host.placeholder="PC LAN IP, e.g. 192.168.1.20"; host.borderStyle = .roundedRect
        host.autocapitalizationType = .none; host.autocorrectionType = .no; host.keyboardType = .numbersAndPunctuation
        resolution.selectedSegmentIndex=0
        let source=UISegmentedControl(items:["OBS network","Real camera"]); source.selectedSegmentIndex=0
        source.addAction(UIAction { [weak self] _ in self?.pipeline.choose(network:source.selectedSegmentIndex==0) },for:.valueChanged)
        let connect=button("Connect / restart input") { [weak self] in
            guard let self=self, let text=self.host.text, !text.isEmpty else { return }
            self.view.endEditing(true); self.pipeline.start(host:text,fullHD:self.resolution.selectedSegmentIndex==1)
        }
        let uplink=button("Start H.264 return to PC :9001") { [weak self] in
            guard let self=self,let text=self.host.text,!text.isEmpty else { return }; self.pipeline.startUplink(host:text)
        }
        let retry=button("Retry camera / show permission status") { [weak self] in self?.pipeline.retryCamera() }
        let reconnect=button("Reconnect network only (keep encoder)") { [weak self] in
            guard let self=self,let text=self.host.text,!text.isEmpty else { return }
            self.pipeline.reconnectNetwork(host:text)
        }
        let stop=button("Stop") { [weak self] in self?.pipeline.stop() }
        status.font = .monospacedSystemFont(ofSize:10,weight:.regular); status.numberOfLines=0
        status.text="Network recovery v4. Tap Connect first. \(ProbeKitIdentity())"
        let stack=UIStackView(arrangedSubviews:[host,resolution,source,connect,reconnect,retry,uplink,stop,status,preview])
        stack.axis = .vertical; stack.spacing=7; stack.translatesAutoresizingMaskIntoConstraints=false
        view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.leadingAnchor,constant:12),
            stack.trailingAnchor.constraint(equalTo:view.safeAreaLayoutGuide.trailingAnchor,constant:-12),
            stack.topAnchor.constraint(equalTo:view.safeAreaLayoutGuide.topAnchor,constant:8),
            stack.bottomAnchor.constraint(equalTo:view.safeAreaLayoutGuide.bottomAnchor,constant:-8),preview.heightAnchor.constraint(greaterThanOrEqualToConstant:180)])
        pipeline.onPreview = { [weak self] in self?.preview.submit($0) }
        pipeline.onStatus = { [weak self] text in DispatchQueue.main.async { self?.status.text=text } }
        NotificationCenter.default.addObserver(self,selector:#selector(background),name:UIApplication.didEnterBackgroundNotification,object:nil)
    }
    private func button(_ title:String,action:@escaping()->Void)->UIButton {
        let b=UIButton(type:.system); b.setTitle(title,for:.normal)
        b.addAction(UIAction { _ in action() },for:.touchUpInside); return b
    }
    @objc private func background() { pipeline.stop(); status.text="Stopped in background; Connect again on resume" }
    deinit { NotificationCenter.default.removeObserver(self) }
}

@main final class AppDelegate:UIResponder,UIApplicationDelegate {
    func application(_ application:UIApplication,didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey:Any]?)->Bool {
        true
    }
    func application(_ application:UIApplication,configurationForConnecting session:UISceneSession,options:UIScene.ConnectionOptions)->UISceneConfiguration {
        let configuration=UISceneConfiguration(name:"Default",sessionRole:session.role)
        configuration.delegateClass=SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate:UIResponder,UIWindowSceneDelegate {
    var window:UIWindow?
    func scene(_ scene:UIScene,willConnectTo session:UISceneSession,options:UIScene.ConnectionOptions) {
        guard let windowScene=scene as? UIWindowScene else { return }
        let window=UIWindow(windowScene:windowScene)
        window.rootViewController=ViewController()
        self.window=window
        window.makeKeyAndVisible()
    }
}
