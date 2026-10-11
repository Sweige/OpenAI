import Foundation
import CoreVideo
import CoreMedia

// Public methods and properties belong to callbackQueue (Pipeline.queue).
// All VideoToolbox calls belong to workQueue. A blocked encoder must not stop RX/UI.
final class EncoderWorker {
    private let callbackQueue: DispatchQueue
    private let workQueue=DispatchQueue(label:"lab.encoder",qos:.userInitiated)
    private lazy var encoder=H264Encoder(queue:workQueue)
    private var generation: UInt64=0
    private(set) var active=false
    private(set) var ready=false
    private(set) var pending=0
    private(set) var dropped=0
    var onInfo: ((String)->Void)?
    var onPacket: ((WirePacket)->Void)?
    init(callbackQueue: DispatchQueue) { self.callbackQueue=callbackQueue }
    func start(width:Int32,height:Int32) {
        guard !active else { return }
        generation &+= 1
        let token=generation
        active=true; ready=false; pending=0; dropped=0
        onInfo?("Encoder start queued: \(width)x\(height)")
        workQueue.async { [self] in
            encoder.onInfo = { [weak self] text in
                NSLog("OBSiPhoneLabEncoder: %@",text)
                self?.callbackQueue.async { [weak self] in
                    guard let self=self, self.generation == token else { return }
                    self.onInfo?(text)
                }
            }
            encoder.onPacket = { [weak self] packet in
                self?.callbackQueue.async { [weak self] in
                    guard let self=self, self.generation == token else { return }
                    self.onPacket?(packet)
                }
            }
            encoder.onFrameComplete = { [weak self] in
                self?.callbackQueue.async { [weak self] in
                    guard let self=self, self.generation == token else { return }
                    self.pending=max(0,self.pending-1)
                }
            }
            do {
                try encoder.start(width:width,height:height)
                callbackQueue.async { [weak self] in
                    guard let self=self, self.generation == token else { return }
                    self.ready=true
                }
            } catch {
                callbackQueue.async { [weak self] in
                    guard let self=self, self.generation == token else { return }
                    self.active=false; self.ready=false
                    self.onInfo?("Encoder start failed: \(error)")
                }
                encoder.stop()
            }
        }
    }
    func submit(_ pixel:CVPixelBuffer,pts:CMTime) {
        guard ready else { return }
        guard pending < 3 else { dropped += 1; return }
        pending += 1
        let token=generation
        workQueue.async { [self] in
            do { try encoder.encode(pixel,pts:pts) }
            catch {
                callbackQueue.async { [weak self] in
                    guard let self=self, self.generation == token else { return }
                    self.pending=max(0,self.pending-1)
                    self.onInfo?("Encoder submit failed: \(error)")
                }
            }
        }
    }
    func stop() {
        generation &+= 1; active=false; ready=false; pending=0
        workQueue.async { [self] in encoder.stop() }
    }
}
