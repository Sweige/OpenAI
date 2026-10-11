import CoreImage
import CoreMedia
import CoreVideo

final class FrameNormalizer {
    let width:Int, height:Int
    private let context=CIContext(options:[.cacheIntermediates:false])
    private var pool:CVPixelBufferPool?
    private let colorspace=CGColorSpace(name:CGColorSpace.itur_709)!
    init(width:Int,height:Int) throws {
        self.width=width; self.height=height
        let attributes:[CFString:Any]=[kCVPixelBufferWidthKey:width,kCVPixelBufferHeightKey:height,
            kCVPixelBufferPixelFormatTypeKey:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey:[:],kCVPixelBufferMetalCompatibilityKey:true]
        try checked(CVPixelBufferPoolCreate(kCFAllocatorDefault,nil,attributes as CFDictionary,&pool),"pixel pool")
    }
    func make(_ input:CVPixelBuffer,pts:CMTime) throws -> (CVPixelBuffer,CMSampleBuffer) {
        guard let pool=pool else { throw LabError.message("No pixel pool") }
        var output:CVPixelBuffer?
        let limits=[kCVPixelBufferPoolAllocationThresholdKey:6] as CFDictionary
        try checked(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault,pool,limits,&output),"pixel allocation")
        guard let output=output else { throw LabError.message("No normalized frame") }
        let image=CIImage(cvPixelBuffer:input)
        let scale=min(CGFloat(width)/image.extent.width,CGFloat(height)/image.extent.height)
        let scaled=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        let centered=scaled.transformed(by:CGAffineTransform(translationX:(CGFloat(width)-scaled.extent.width)/2-scaled.extent.minX,
                                                             y:(CGFloat(height)-scaled.extent.height)/2-scaled.extent.minY))
        let rect=CGRect(x:0,y:0,width:CGFloat(width),height:CGFloat(height))
        let composite=centered.composited(over:CIImage(color:.black).cropped(to:rect))
        CVBufferSetAttachment(output,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,.shouldPropagate)
        CVBufferSetAttachment(output,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,.shouldPropagate)
        context.render(composite,to:output,bounds:rect,colorSpace:colorspace)
        var description:CMVideoFormatDescription?
        try checked(CMVideoFormatDescriptionCreateForImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:output,formatDescriptionOut:&description),"image format")
        var timing=CMSampleTimingInfo(duration:CMTime(value:1,timescale:30),presentationTimeStamp:pts,decodeTimeStamp:.invalid)
        var sample:CMSampleBuffer?
        try checked(CMSampleBufferCreateReadyWithImageBuffer(allocator:kCFAllocatorDefault,imageBuffer:output,formatDescription:description!,sampleTiming:&timing,sampleBufferOut:&sample),"image sample")
        return (output,sample!)
    }
}
