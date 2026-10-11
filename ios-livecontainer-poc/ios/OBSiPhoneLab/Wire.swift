import Foundation

struct WirePacket {
    let sequence: UInt32
    let pts: UInt64
    let key: Bool
    let payload: Data
    func encoded() -> Data {
        var d = Data([0x4f, 0x42, 0x53, 0x43, 1, 1, 0, key ? 1 : 0])
        d.put(UInt32(payload.count)); d.put(sequence); d.put(pts)
        d.append(payload); return d
    }
}
extension Data {
    mutating func put<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
    func uint(_ offset: Int, _ count: Int) -> UInt64 {
        self[(startIndex+offset)..<(startIndex+offset+count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
final class WireParser {
    private var buffer = Data()
    func reset() { buffer.removeAll(keepingCapacity: false) }
    func feed(_ bytes: Data) throws -> [WirePacket] {
        buffer.append(bytes)
        var packets: [WirePacket] = []
        while buffer.count >= 24 {
            guard Array(buffer.prefix(6)) == [0x4f, 0x42, 0x53, 0x43, 1, 1] else { throw LabError.message("Invalid OBSC header") }
            let size = Int(buffer.uint(8, 4))
            guard size > 0 && size <= 8*1024*1024 else { throw LabError.message("Packet length rejected") }
            guard buffer.uint(16,8) <= UInt64(Int64.max) else { throw LabError.message("PTS out of range") }
            if buffer.count < 24+size { break }
            packets.append(WirePacket(sequence: UInt32(buffer.uint(12,4)), pts: buffer.uint(16,8),
                                      key: buffer.uint(6,2)&1 != 0, payload: Data(buffer.dropFirst(24).prefix(size))))
            buffer = Data(buffer.dropFirst(24+size))
        }
        return packets
    }
}
enum LabError: Error { case message(String), status(String, OSStatus) }
func checked(_ result: OSStatus, _ operation: String) throws {
    if result != noErr { throw LabError.status(operation, result) }
}

func splitAnnexB(_ data: Data) -> [Data] {
    let b = [UInt8](data)
    var starts: [(Int,Int)] = []; var i=0
    while i+3 <= b.count {
        if i+4 <= b.count && b[i] == 0 && b[i+1] == 0 && b[i+2] == 0 && b[i+3] == 1 {
            starts.append((i,4)); i += 4
        } else if b[i] == 0 && b[i+1] == 0 && b[i+2] == 1 {
            starts.append((i,3)); i += 3
        } else { i += 1 }
    }
    return starts.enumerated().compactMap { j,s in
        let end = j+1 < starts.count ? starts[j+1].0 : b.count
        return end > s.0+s.1 ? Data(b[(s.0+s.1)..<end]) : nil
    }
}
