import AVFoundation
import CoreVideo

final class Camera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let queue: DispatchQueue
    private let session=AVCaptureSession()
    private var configured=false
    var onFrame: ((CVPixelBuffer)->Void)?
    var onInfo: ((String)->Void)?
    init(queue:DispatchQueue) { self.queue=queue; super.init() }
    func start() {
        AVCaptureDevice.requestAccess(for:.video) { [weak self] allowed in
            guard let self=self else { return }
            self.queue.async {
                guard allowed else { self.onInfo?("Camera permission denied"); return }
                do {
                    if !self.configured { try self.configure() }
                    if !self.session.isRunning { self.session.startRunning() }
                } catch { self.onInfo?("Camera: \(error)") }
            }
        }
    }
    private func configure() throws {
        session.beginConfiguration(); defer { session.commitConfiguration() }
        // Log capabilities on the actual device; an available API is not proof
        // that an iPhone exposes an attached UVC camera.
        let discovered=AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.external],mediaType:.video,position:.unspecified)
        for d in discovered.devices {
            NSLog("Camera discovery: name=%@ type=%@ position=%ld formats=%ld",d.localizedName,d.deviceType.rawValue,d.position.rawValue,d.formats.count)
        }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.sessionPreset = .hd1920x1080
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
        if let pixel=CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame?(pixel) }
    }
    func stop() { if session.isRunning { session.stopRunning() } }
}
