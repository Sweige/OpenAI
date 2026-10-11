import AVFoundation
import CoreVideo

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue: DispatchQueue
    private let session=AVCaptureSession()
    private var configured=false
    private var wantsRunning=false
    private var requesting=false
    private var generation:UInt64=0
    private var frames=0
    private var observers:[NSObjectProtocol]=[]
    var onFrame: ((CVPixelBuffer)->Void)?
    var onInfo: ((String)->Void)?
    init(queue:DispatchQueue) {
        self.queue=queue; super.init()
        let center=NotificationCenter.default
        observers.append(center.addObserver(forName:AVCaptureSession.runtimeErrorNotification,object:session,queue:nil) { [weak self] note in
            let error=note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let text="Camera runtime error: domain=\(error?.domain ?? "unknown") code=\(error?.code ?? 0) \(error?.localizedDescription ?? "")"
            self?.queue.async { [weak self] in self?.onInfo?(text) }
        })
        observers.append(center.addObserver(forName:AVCaptureSession.wasInterruptedNotification,object:session,queue:nil) { [weak self] note in
            let reason=note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
            let text="Camera interrupted, reason=\(reason?.intValue ?? -1)"
            self?.queue.async { [weak self] in self?.onInfo?(text) }
        })
        observers.append(center.addObserver(forName:AVCaptureSession.interruptionEndedNotification,object:session,queue:nil) { [weak self] _ in
            self?.queue.async { [weak self] in self?.onInfo?("Camera interruption ended; tap Retry camera") }
        })
    }
    private var authorization:String {
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }
    func start() {
        wantsRunning=true
        onInfo?("Camera auth=\(authorization)")
        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized:
            startAuthorized()
        case .notDetermined:
            guard !requesting else { onInfo?("Camera auth=notDetermined; awaiting permission response"); return }
            requesting=true
            let token=generation
            // Present any first-use prompt from the foreground UI thread.
            DispatchQueue.main.async { [weak self] in
                guard let self=self else { return }
                AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
                    guard let self=self else { return }
                    self.queue.async {
                        guard self.generation == token, self.wantsRunning else { return }
                        self.requesting=false
                        self.onInfo?("Camera request allowed=\(allowed), auth=\(self.authorization)")
                        if allowed { self.startAuthorized() }
                    }
                }
            }
        case .denied, .restricted:
            onInfo?("Camera auth=\(authorization); check LiveContainer camera permission in iOS Settings")
        @unknown default:
            onInfo?("Camera auth=unknown")
        }
    }
    private func startAuthorized() {
        guard wantsRunning else { return }
        do {
            if !configured { try configure() }
            if !session.isRunning { session.startRunning() }
            onInfo?("Camera auth=\(authorization), running=\(session.isRunning), interrupted=\(session.isInterrupted), inputs=\(session.inputs.count), outputs=\(session.outputs.count)")
        } catch {
            let detail=error as NSError
            onInfo?("Camera auth=\(authorization), error=\(detail.domain)/\(detail.code): \(error)")
        }
    }
    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        // Log capabilities on the actual device; an available API is not proof
        // that an iPhone exposes an attached UVC camera.
        let discovered=AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external],mediaType:.video,position:.unspecified)
        onInfo?("Camera auth=\(authorization), discovered=\(discovered.devices.count); configuring")
        for d in discovered.devices {
            NSLog("Camera discovery: name=%@ type=%@ position=%ld formats=%ld",d.localizedName,d.deviceType.rawValue,d.position.rawValue,d.formats.count)
        }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        else if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        else { throw LabError.message("No supported capture preset") }
        guard let device=AVCaptureDevice.default(.builtInWideAngleCamera,for:.video,position:.back) else { throw LabError.message("No camera") }
        let input=try AVCaptureDeviceInput(device:device)
        guard session.canAddInput(input) else { throw LabError.message("Camera input rejected") }
        session.addInput(input)
        let output=AVCaptureVideoDataOutput()
        output.videoSettings=[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.alwaysDiscardsLateVideoFrames=true
        output.setSampleBufferDelegate(self,queue:queue)
        guard session.canAddOutput(output) else { throw LabError.message("Camera output rejected") }
        session.addOutput(output)
        if let connection=output.connection(with:.video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle=90
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) {
            device.activeVideoMinFrameDuration=CMTime(value:1,timescale:30)
            device.activeVideoMaxFrameDuration=CMTime(value:1,timescale:30)
        }
        configured=true
    }
    func captureOutput(_ output:AVCaptureOutput,didOutput sampleBuffer:CMSampleBuffer,from connection:AVCaptureConnection) {
        if let pixel=CMSampleBufferGetImageBuffer(sampleBuffer) {
            frames += 1
            if frames == 1 {
                onInfo?("Camera auth=\(authorization), running=\(session.isRunning), first frame=\(CVPixelBufferGetWidth(pixel))x\(CVPixelBufferGetHeight(pixel))")
            }
            onFrame?(pixel)
        }
    }
    func stop() {
        generation &+= 1; wantsRunning=false; requesting=false; frames=0
        if session.isRunning { session.stopRunning() }
    }
    deinit { for token in observers { NotificationCenter.default.removeObserver(token) } }
}
