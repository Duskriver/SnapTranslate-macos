import AppKit
import CoreVideo
// Xcode 16's SDK lacks Sendable annotations on its immutable content snapshot.
// We consume that snapshot on the main actor, rather than sharing it ourselves.
@preconcurrency import ScreenCaptureKit

struct CapturedImage: Sendable {
    let data: Data
    let mimeType: String
}

enum CaptureError: LocalizedError {
    case missingDisplay, emptySelection, encodingFailed, imageTooLarge
    var errorDescription: String? {
        switch self {
        case .missingDisplay: "找不到所选显示器，请重新截图。"
        case .emptySelection: "截图区域过小，请重新选择。"
        case .encodingFailed: "无法处理截图，请重试。"
        case .imageTooLarge: "截图内容过大，请缩小选择区域。"
        }
    }
}

enum ScreenCapture {
    @MainActor
    static func captureScreens(
        excludingProcessIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]
    ) async throws -> [UInt32: CGImage] {
        try Task.checkCancellation()
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return [:] }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let ownApps = content.applications.filter { excludingProcessIDs.contains($0.processID) }
        var snapshots: [UInt32: CGImage] = [:]
        for screen in screens {
            try Task.checkCancellation()
            guard let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                continue
            }
            let displayID = displayNumber.uint32Value
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                continue
            }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = CGRect(origin: .zero, size: screen.frame.size)
            let scale = screen.backingScaleFactor
            configuration.width = max(1, Int((screen.frame.width * scale).rounded()))
            configuration.height = max(1, Int((screen.frame.height * scale).rounded()))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.colorSpaceName = screen.colorSpace?.cgColorSpace?.isWideGamutRGB == true
                ? CGColorSpace.displayP3
                : CGColorSpace.sRGB
            configuration.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            snapshots[displayID] = image
        }
        return snapshots
    }

    static func crop(_ snapshot: CGImage, rect globalRect: NSRect, on screen: NSScreen) throws -> CGImage {
        let screenFrame = screen.frame
        let rect = globalRect.intersection(screenFrame)
        guard rect.width >= 8, rect.height >= 8 else { throw CaptureError.emptySelection }
        guard screenFrame.width > 0, screenFrame.height > 0 else { throw CaptureError.missingDisplay }
        let localX = rect.minX - screenFrame.minX
        let localY = screenFrame.maxY - rect.maxY
        let scaleX = CGFloat(snapshot.width) / screenFrame.width
        let scaleY = CGFloat(snapshot.height) / screenFrame.height
        let rawPixelRect = CGRect(
            x: localX * scaleX,
            y: localY * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: snapshot.width, height: snapshot.height)
        let pixelRect = rawPixelRect.intersection(bounds)
        guard !pixelRect.isEmpty, let cropped = snapshot.cropping(to: pixelRect) else {
            throw CaptureError.encodingFailed
        }
        // Bound a single bitmap to 8 megapixels, retaining native resolution for ordinary crops.
        let nativeWidth = CGFloat(cropped.width)
        let nativeHeight = CGFloat(cropped.height)
        let factor = min(1, 4096 / max(nativeWidth, nativeHeight), sqrt(8_000_000 / (nativeWidth * nativeHeight)))
        guard factor < 1 else { return cropped }
        let targetWidth = max(1, Int((nativeWidth * factor).rounded()))
        let targetHeight = max(1, Int((nativeHeight * factor).rounded()))
        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            throw CaptureError.encodingFailed
        }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let scaled = context.makeImage() else { throw CaptureError.encodingFailed }
        return scaled
    }

    @MainActor
    static func capture(
        _ region: SelectedRegion,
        excludingProcessIDs: Set<Int32> = [ProcessInfo.processInfo.processIdentifier]
    ) async throws -> CapturedImage {
        try Task.checkCancellation()
        guard let displayNumber = region.screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.missingDisplay
        }
        let screenFrame = region.screen.frame
        let scale = region.screen.backingScaleFactor
        let rect = region.rect.intersection(screenFrame)
        guard rect.width >= 8, rect.height >= 8 else { throw CaptureError.emptySelection }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayNumber.uint32Value }) else {
            throw CaptureError.missingDisplay
        }
        // Exclude our windows, even if the compositor hasn't removed the selection overlay yet.
        let ownApps = content.applications.filter { excludingProcessIDs.contains($0.processID) }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(x: rect.minX - screenFrame.minX, y: screenFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
        // Bound a single bitmap to 8 megapixels, retaining native resolution for ordinary crops.
        let nativeWidth = rect.width * scale
        let nativeHeight = rect.height * scale
        let factor = min(1, 4096 / max(nativeWidth, nativeHeight), sqrt(8_000_000 / (nativeWidth * nativeHeight)))
        configuration.width = max(1, Int((nativeWidth * factor).rounded()))
        configuration.height = max(1, Int((nativeHeight * factor).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.captureResolution = .best
        // Admit before allocating a bitmap, so rapid replacements wait without
        // retaining screenshots while the previous ImageIO call finishes.
        return try await PNGEncoder.shared.captureAndEncode { @MainActor in
            try Task.checkCancellation()
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }
}
