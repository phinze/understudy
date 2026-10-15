import CoreVideo
import VideoToolbox

/// Converts frames to one pixel format with VideoToolbox, into IOSurface-backed
/// buffers that can cross into the camera extension's process. Live video is
/// NV12 end to end; this is for the parts that draw or save in BGRA.
final class PixelTransfer {
    private let format: OSType
    private var session: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)

    init(to format: OSType) {
        self.format = format
        VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &session)
        if let session, format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            VTSessionSetProperty(
                session, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        }
    }

    /// `source` in this transfer's format, or nil if the conversion failed.
    func convert(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        if pool == nil || poolSize != (width, height) {
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ]
            pool = nil
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
            poolSize = (width, height)
        }
        var out: CVPixelBuffer?
        guard let session, let pool,
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
            let out,
            VTPixelTransferSessionTransferImage(session, from: source, to: out) == noErr
        else { return nil }
        return out
    }
}
