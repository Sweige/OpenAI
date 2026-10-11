import Foundation
import Network

// All methods and callbacks run on Pipeline.queue. Never mutate state from UI.
final class StreamClient {
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private let parser = WireParser()
    var onPacket: ((WirePacket) -> Void)?
    var onState: ((String) -> Void)?
    init(queue: DispatchQueue) { self.queue=queue }
    func connect(host: String, port: UInt16) {
        stop()
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        connection=c
        c.stateUpdateHandler = { [weak self, weak c] state in
            guard let self=self, let c=c, self.connection === c else { return }
            self.onState?("RX: \(state)")
            if case .ready = state { self.read(c) }
        }
        c.start(queue: queue)
    }
    private func read(_ c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data,_,complete,error in
            guard let self=self, let c=c, self.connection === c else { return }
            do {
                if let data=data { for p in try self.parser.feed(data) { self.onPacket?(p) } }
            } catch { self.onState?("RX parse: \(error)"); self.stop(); return }
            if complete || error != nil { self.onState?("RX ended. Tap Connect to restart."); self.stop(); return }
            self.read(c)
        }
    }
    func stop() { connection?.cancel(); connection=nil; parser.reset() }
}

final class Uplink {
    private let queue: DispatchQueue
    private var c: NWConnection?
    private var ready=false
    private var pending=0
    private var waitIDR=true
    var onState: ((String)->Void)?
    init(queue: DispatchQueue) { self.queue=queue }
    func connect(host: String, port: UInt16) {
        stop()
        let x=NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        c=x
        x.stateUpdateHandler = { [weak self, weak x] state in
            guard let self=self, let x=x, self.c === x else { return }
            self.onState?("TX: \(state)")
            if case .ready = state { self.ready=true }
            if case .failed = state { self.stop() }
        }
        x.start(queue: queue)
    }
    func send(_ packet: WirePacket) {
        guard ready, let x=c else { return }
        // Never discard one encoded reference frame and then continue its P frames.
        if pending >= 3 { waitIDR=true; return }
        if waitIDR && !packet.key { return }
        waitIDR=false; pending += 1
        x.send(content: packet.encoded(), completion: .contentProcessed { [weak self, weak x] error in
            guard let self=self, let x=x, self.c === x else { return }
            self.pending=max(0,self.pending-1)
            if let error=error { self.onState?("TX error \(error)"); self.stop() }
        })
    }
    func stop() { c?.cancel(); c=nil; ready=false; pending=0; waitIDR=true }
}
