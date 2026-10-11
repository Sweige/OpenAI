import Foundation
import VideoToolbox

final class H264Encoder {
    private let queue: DispatchQueue
    private var generation: UInt64=0
    private var session: VTCompressionSession?
    private var sequence: UInt32=0
    private var firstSubmit=true
    private var firstOutput=true
    var onPacket: ((WirePacket)->Void)?
    var onInfo: ((String)->Void)?
    var onFrameComplete: (()->Void)?
    init(queue: DispatchQueue) { self.queue=queue }
    func start(width:Int32,height:Int32) throws {
        stop(); sequence=0; firstSubmit=true; firstOutput=true
        let spec:[CFString:Any]=[kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder:true]
        onInfo?("Encoder VTCompressionSessionCreate: \(width)x\(height)")
        try checked(VTCompressionSessionCreate(allocator:kCFAllocatorDefault,width:width,height:height,codecType:kCMVideoCodecType_H264,
            encoderSpecification:spec as CFDictionary,imageBufferAttributes:nil,compressedDataAllocator:nil,outputCallback:nil,refcon:nil,compressionSessionOut:&session),"encoder create")
        guard let s=session else { throw LabError.message("Missing encoder") }
        let properties:[(CFString,CFTypeRef)] = [(kVTCompressionPropertyKey_RealTime,kCFBooleanTrue as CFTypeRef),
                            (kVTCompressionPropertyKey_AllowFrameReordering,kCFBooleanFalse as CFTypeRef),
                            (kVTCompressionPropertyKey_ExpectedFrameRate,NSNumber(value:30) as CFTypeRef),
                            (kVTCompressionPropertyKey_MaxKeyFrameInterval,NSNumber(value:30) as CFTypeRef),
                            (kVTCompressionPropertyKey_AverageBitRate,NSNumber(value:6_000_000) as CFTypeRef),
                            (kVTCompressionPropertyKey_ProfileLevel,kVTProfileLevel_H264_Baseline_AutoLevel)]
        for (key,value) in properties {
            onInfo?("Encoder set \(key)")
            try checked(VTSessionSetProperty(s,key:key,value:value),"encoder property \(key)")
        }
        onInfo?("Encoder VTCompressionSessionPrepareToEncodeFrames")
        try checked(VTCompressionSessionPrepareToEncodeFrames(s),"encoder prepare")
        onInfo?("Encoder ready; awaiting first frame")
    }
    func encode(_ pixel:CVPixelBuffer,pts:CMTime) throws {
        guard let s=session else { return }
        let currentGeneration=generation
        if firstSubmit { firstSubmit=false; onInfo?("Encoder first VTCompressionSessionEncodeFrame") }
        try checked(VTCompressionSessionEncodeFrame(s,imageBuffer:pixel,presentationTimeStamp:pts,duration:CMTime(value:1,timescale:30),
            frameProperties:nil,infoFlagsOut:nil, outputHandler: { [weak self] status,_,sample in
                guard let self=self else { return }
                self.queue.async {
                    guard self.generation == currentGeneration else { return }
                    defer { self.onFrameComplete?() }
                    if status != noErr { self.onInfo?("encode callback \(status)"); return }
                    guard let sample=sample else { return }
                    do { try self.output(sample) } catch { self.onInfo?("encode output \(error)") }
                }
            }),"encode")
    }
    private func output(_ sample:CMSampleBuffer) throws {
        guard CMSampleBufferDataIsReady(sample), let block=CMSampleBufferGetDataBuffer(sample),let fmt=CMSampleBufferGetFormatDescription(sample) else { return }
        let attachments=CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[CFString:Any]]
        let key=(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        var output=Data([0,0,0,1,9,0xf0])
        var headerLength:Int32=4
        if key {
            for index in 0..<2 {
                var ptr:UnsafePointer<UInt8>?; var size=0; var count=0
                try checked(CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt,parameterSetIndex:index,parameterSetPointerOut:&ptr,
                    parameterSetSizeOut:&size,parameterSetCountOut:&count,nalUnitHeaderLengthOut:&headerLength),"encoder parameter sets")
                if let ptr=ptr { output.append(contentsOf:[0,0,0,1]); output.append(ptr,count:size) }
            }
        }
        // Copy works even for non-contiguous CMBlockBuffer memory.
        let count=CMBlockBufferGetDataLength(block); var data=Data(count:count)
        try data.withUnsafeMutableBytes { b in try checked(CMBlockBufferCopyDataBytes(block,atOffset:0,dataLength:count,destination:b.baseAddress!),"encoder block copy") }
        var offset=0
        while offset+Int(headerLength) <= data.count {
            let length=Int(data.uint(offset,Int(headerLength))); offset += Int(headerLength)
            guard length>0 && offset+length<=data.count else { throw LabError.message("Bad AVCC output") }
            output.append(contentsOf:[0,0,0,1]); output.append(data.subdata(in:offset..<offset+length)); offset += length
        }
        let pts=CMSampleBufferGetPresentationTimeStamp(sample)
        let packet=WirePacket(sequence:sequence,pts:UInt64(max(0,CMTimeGetSeconds(pts)*1_000_000)),key:key,payload:output)
        if firstOutput { firstOutput=false; onInfo?("Encoder producing H.264 packets") }
        sequence &+= 1; onPacket?(packet)
    }
    func stop() {
        generation &+= 1
        if let s=session {
            onInfo?("Encoder completing old frames")
            VTCompressionSessionCompleteFrames(s,untilPresentationTimeStamp:.invalid)
            VTCompressionSessionInvalidate(s)
        }
        session=nil
    }
    deinit { stop() }
}
