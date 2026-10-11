import Foundation
import QuartzCore
import CoreMedia
import CoreVideo

final class Pipeline {
    let queue=DispatchQueue(label:"lab.media",qos:.userInteractive)
    private lazy var receiver=StreamClient(queue:queue)
    private lazy var decoder=H264Decoder(queue:queue)
    private lazy var encoder=H264Encoder(queue:queue)
    private lazy var camera=Camera(queue:queue)
    private lazy var uplink=Uplink(queue:queue)
    private var normalizer:FrameNormalizer?
    private var timer:DispatchSourceTimer?
    private var network:(CVPixelBuffer,Double)?
    private var local:(CVPixelBuffer,Double)?
    private var useNetwork=true
    private var encoding=false
    private var epoch=0.0
    private var lastPTS=CMTime.invalid
    private var rxCount=0,txCount=0,ticks=0
    var onPreview:((CMSampleBuffer)->Void)?
    var onStatus:((String)->Void)?
    init() {
        decoder.onFrame = { [weak self] p,_ in
            guard let self=self else { return }
            // Decoder marshals callbacks to this queue and retains CVPixelBuffer.
            self.network=(p,CACurrentMediaTime()); self.rxCount += 1
        }
    }
    func start(host:String,fullHD:Bool) {
        queue.async { [self] in
            stopInternal()
            do { normalizer=try FrameNormalizer(width:fullHD ? 1080:720,height:fullHD ? 1920:1280) }
            catch { onStatus?("Pool: \(error)"); return }
            let info:(String)->Void = { [weak self] in self?.onStatus?($0) }
            receiver.onState=info; decoder.onInfo=info; camera.onInfo=info; uplink.onState=info; encoder.onInfo=info
            receiver.onPacket = { [weak self] p in
                do { try self?.decoder.decode(p) } catch { self?.onStatus?("RX decode \(error)") }
            }
            camera.onFrame = { [weak self] p in self?.local=(p,CACurrentMediaTime()) }
            encoder.onPacket = { [weak self] p in
                guard let self=self else { return }
                self.uplink.send(p); self.txCount += 1
            }
            epoch=CACurrentMediaTime(); lastPTS = .invalid; rxCount=0; txCount=0; ticks=0
            camera.start(); receiver.connect(host:host,port:9000)
            let t=DispatchSource.makeTimerSource(queue:queue)
            t.schedule(deadline:.now(),repeating:.nanoseconds(33_333_333),leeway:.milliseconds(2))
            t.setEventHandler { [weak self] in self?.tick() }
            timer=t; t.resume()
        }
    }
    func choose(network:Bool) { queue.async { self.useNetwork=network } }
    func startUplink(host:String) {
        queue.async { [self] in
            guard let n=normalizer else { onStatus?("Connect input first"); return }
            do { try encoder.start(width:Int32(n.width),height:Int32(n.height)); uplink.connect(host:host,port:9001); encoding=true }
            catch { onStatus?("Encoder: \(error)"); encoding=false; encoder.stop() }
        }
    }
    private func tick() {
        ticks += 1
        let now=CACurrentMediaTime()
        let selected=useNetwork ? network:local
        if ticks%30 == 0 {
            onStatus?("\(useNetwork ? "OBS":"Camera") RX decoded=\(rxCount), TX encoded=\(txCount), source age=\(selected.map{Int((now-$0.1)*1000)} ?? -1) ms")
        }
        // A stale input stops producing encoded output; do not silently stream it forever.
        guard let (input,arrival)=selected, now-arrival < 0.5, let n=normalizer else { return }
        let pts=CMTime(seconds:now-epoch,preferredTimescale:60_000)
        if lastPTS.isValid && CMTimeCompare(pts,lastPTS)<=0 { return }
        lastPTS=pts
        do {
            let (pixel,sample)=try n.make(input,pts:pts)
            onPreview?(sample)
            if encoding { try encoder.encode(pixel,pts:pts) }
        } catch { onStatus?("Frame: \(error)") }
    }
    func stop() { queue.async { self.stopInternal() } }
    private func stopInternal() {
        timer?.cancel(); timer=nil; receiver.stop(); camera.stop(); decoder.reset(); encoder.stop(); uplink.stop()
        network=nil; local=nil; normalizer=nil; encoding=false
    }
}
