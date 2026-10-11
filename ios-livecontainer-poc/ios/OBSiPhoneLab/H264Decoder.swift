import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class H264Decoder {
    private let queue: DispatchQueue
    private var generation: UInt64=0
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps=Data(), pps=Data()
    private var needsIDR=true
    var onFrame: ((CVPixelBuffer,CMTime)->Void)?
    var onInfo: ((String)->Void)?
    init(queue: DispatchQueue) { self.queue=queue }
    func reset() {
        generation &+= 1
        if let session=session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
        session=nil; format=nil; sps=Data(); pps=Data(); needsIDR=true
    }
    deinit { if let session=session { VTDecompressionSessionInvalidate(session) } }
    func decode(_ packet: WirePacket) throws {
        let nals=splitAnnexB(packet.payload)
        var changed=false
        for n in nals {
            guard let first=n.first else { continue }
            if first&31 == 7 && n != sps { sps=n; changed=true }
            if first&31 == 8 && n != pps { pps=n; changed=true }
        }
        if changed || session == nil {
            guard !sps.isEmpty && !pps.isEmpty else { return }
            if let session=session { VTDecompressionSessionWaitForAsynchronousFrames(session); VTDecompressionSessionInvalidate(session) }
            session=nil; needsIDR=true
            generation &+= 1
            try makeSession()
        }
        let idr=nals.contains { ($0.first ?? 0)&31 == 5 }
        if needsIDR && !idr { return }
        guard let session=session, let format=format else { return }
        var avcc=Data()
        for n in nals where [1,5,6].contains(Int((n.first ?? 0)&31)) { avcc.put(UInt32(n.count)); avcc.append(n) }
        guard !avcc.isEmpty else { return }
        var block: CMBlockBuffer?
        try checked(CMBlockBufferCreateWithMemoryBlock(allocator:kCFAllocatorDefault, memoryBlock:nil, blockLength:avcc.count,
            blockAllocator:kCFAllocatorDefault, customBlockSource:nil, offsetToData:0, dataLength:avcc.count, flags:0, blockBufferOut:&block), "block create")
        guard let block=block else { throw LabError.message("Missing block") }
        try avcc.withUnsafeBytes { b in try checked(CMBlockBufferReplaceDataBytes(with:b.baseAddress!, blockBuffer:block, offsetIntoDestination:0, dataLength:avcc.count),"block copy") }
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:CMTime(value:Int64(packet.pts),timescale:1_000_000),decodeTimeStamp:.invalid)
        var size=avcc.count; var sample: CMSampleBuffer?
        try checked(CMSampleBufferCreateReady(allocator:kCFAllocatorDefault, dataBuffer:block, formatDescription:format, sampleCount:1,
            sampleTimingEntryCount:1, sampleTimingArray:&timing, sampleSizeEntryCount:1, sampleSizeArray:&size, sampleBufferOut:&sample), "compressed sample")
        guard let sample=sample else { return }
        needsIDR=false
        // Synchronous decode keeps the serial lab queue and buffer ownership simple.
        // Production: bounded asynchronous decoder queue + generation token on reset.
        let currentGeneration=generation
        let result=VTDecompressionSessionDecodeFrame(session, sampleBuffer:sample, flags:[], infoFlagsOut:nil, outputHandler: { [weak self] status,_,pixel,pts,_ in
            guard let self=self else { return }
            self.queue.async {
                guard self.generation == currentGeneration else { return }
                if status == noErr, let pixel=pixel { self.onFrame?(pixel,pts) }
                else { self.needsIDR=true; self.onInfo?("decode callback OSStatus=\(status)") }
            }
        })
        if result != noErr { needsIDR=true; throw LabError.status("decode",result) }
    }
    private func makeSession() throws {
        var description: CMFormatDescription?
        let result=sps.withUnsafeBytes { s in pps.withUnsafeBytes { p in
            let pointers=[s.bindMemory(to:UInt8.self).baseAddress!,p.bindMemory(to:UInt8.self).baseAddress!]
            let sizes=[sps.count,pps.count]
            return pointers.withUnsafeBufferPointer { pp in sizes.withUnsafeBufferPointer { ss in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator:kCFAllocatorDefault,parameterSetCount:2,
                    parameterSetPointers:pp.baseAddress!,parameterSetSizes:ss.baseAddress!,nalUnitHeaderLength:4,formatDescriptionOut:&description)
            } }
        } }
        try checked(result,"SPS/PPS format")
        guard let description=description else { throw LabError.message("Missing format") }
        format=description
        let attrs:[CFString:Any]=[kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,kCVPixelBufferIOSurfacePropertiesKey:[:]]
        let spec:[CFString:Any]=[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:true]
        try checked(VTDecompressionSessionCreate(allocator:kCFAllocatorDefault, formatDescription:description,
            decoderSpecification:spec as CFDictionary, imageBufferAttributes:attrs as CFDictionary, outputCallback:nil, decompressionSessionOut:&session),"VT decoder create (hardware required)")
        if let session=session {
            _ = VTSessionSetProperty(session,key:kVTDecompressionPropertyKey_RealTime,value:kCFBooleanTrue)
            var value: CFTypeRef?
            let status=VTSessionCopyProperty(session,key:kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,allocator:kCFAllocatorDefault,valueOut:&value)
            onInfo?("HW decoder property status=\(status), value=\(String(describing:value))")
        }
    }
}
