#if os(tvOS)
import AVKit
import CoreMedia
import UIKit

/// Adapted from AetherEngine Sources/AetherEngine/Display/DisplayCriteriaController.swift apply():
/// asks tvOS for the panel mode (frame rate, SDR or HDR10) through AVDisplayManager.
@MainActor
public enum DisplayModeController {
    public static func apply(hdr: Bool, refreshRate: Float, window: UIWindow) {
        let manager = window.avDisplayManager
        guard manager.isDisplayCriteriaMatchingEnabled else { return }
        let extensions: NSDictionary? = hdr ? [
            kCMFormatDescriptionExtension_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            kCMFormatDescriptionExtension_TransferFunction: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_2020,
        ] : nil
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_HEVC,
                                       width: 3840, height: 2160, extensions: extensions, formatDescriptionOut: &format)
        guard let format else { return }
        manager.preferredDisplayCriteria = AVDisplayCriteria(refreshRate: refreshRate, formatDescription: format)
    }

    public static func reset(window: UIWindow) {
        window.avDisplayManager.preferredDisplayCriteria = nil
    }
}
#endif
