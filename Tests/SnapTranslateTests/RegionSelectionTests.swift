import AppKit
import Testing
@testable import SnapTranslate

extension AppKitTests {
    @MainActor
    @Suite(.serialized)
    struct RegionSelectionTests {
        private static let application: NSApplication = {
            let application = NSApplication.shared
            application.setActivationPolicy(.accessory)
            application.finishLaunching()
            return application
        }()

        @Test func firstDragInNonKeyPanelSelectsRegion() throws {
            try verifyFirstDrag(initiallyKey: false)
        }

        @Test func firstDragInKeyPanelSelectsRegion() throws {
            try verifyFirstDrag(initiallyKey: true)
        }

        private func verifyFirstDrag(initiallyKey: Bool) throws {
            _ = Self.application
            // Two real panels reproduce the focus state of two display overlays,
            // even on a machine with only one display. They remain invisible.
            let firstPanel = makePanel(x: 0)
            let targetPanel = makePanel(x: 120)
            defer {
                for panel in [firstPanel, targetPanel] {
                    panel.orderOut(nil)
                    panel.close()
                    panel.contentView = nil
                }
            }

            let view = SelectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
            targetPanel.contentView = view
            var selections: [NSRect] = []
            view.onSelection = { selections.append($0) }
            firstPanel.orderFrontRegardless()
            targetPanel.orderFrontRegardless()
            (initiallyKey ? targetPanel : firstPanel).makeKey()
            try #require(targetPanel.isKeyWindow == initiallyKey)
            try #require(firstPanel.isKeyWindow != initiallyKey)

            // Dispatch through NSWindow so AppKit applies its first-click policy.
            // Calling view.mouseDown directly would hide the multi-display bug.
            // These events stay in this process; no OS event posting or capture occurs.
            targetPanel.sendEvent(try mouseEvent(.leftMouseDown, at: NSPoint(x: 10, y: 20), in: targetPanel))
            targetPanel.sendEvent(try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 90), in: targetPanel))
            #expect(selections.isEmpty)
            targetPanel.sendEvent(try mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 90), in: targetPanel))

            #expect(targetPanel.isKeyWindow)
            #expect(selections == [NSRect(x: 10, y: 20, width: 70, height: 70)])
        }

        @Test func preCapturedSnapshotCropsToSelectedRegionAndReleasesBackdrop() throws {
            _ = Self.application
            let screen = try #require(NSScreen.main)
            let displayID = try #require(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).uint32Value
            let snapshot = try makeTestSnapshot(width: Int(screen.frame.width), height: Int(screen.frame.height))

            let selector = RegionSelector(notificationCenter: NotificationCenter())
            var selected: SelectedRegion?
            selector.begin(snapshots: [displayID: snapshot]) { selected = $0 }
            defer { selector.cancel() }

            let panel = try #require(NSApp.windows.compactMap { $0 as? SelectionPanel }.first { $0.frame == screen.frame })
            panel.alphaValue = 0
            let view = try #require(panel.contentView as? SelectionView)
            let backdrop = try #require(view.layer?.sublayers?.first)
            #expect(backdrop.contents != nil)

            panel.sendEvent(try mouseEvent(.leftMouseDown, at: NSPoint(x: 20, y: 30), in: panel))
            panel.sendEvent(try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 110), in: panel))
            panel.sendEvent(try mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 110), in: panel))

            #expect(!selector.isSelecting)
            #expect(backdrop.contents == nil)
            let region = try #require(selected)
            let cropped = try #require(region.snapshot)
            #expect(cropped.width == 60)
            #expect(cropped.height == 80)
        }

        @Test func cropConvertsAppKitBottomLeftCoordinatesAndRejectsTinyRects() throws {
            let screen = try #require(NSScreen.main)
            let frame = screen.frame
            // 2x Retina snapshot with a bright red square in the top-left quarter (AppKit: high y, low x).
            let width = Int(frame.width * 2)
            let height = Int(frame.height * 2)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            // CoreGraphics CGContext y=0 is bottom-left in bitmap coordinates, matching AppKit.
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: 40, y: height - 140, width: 100, height: 100))
            let snapshot = try #require(context.makeImage())

            let tiny = NSRect(x: frame.minX + 10, y: frame.maxY - 20, width: 5, height: 5)
            #expect(throws: CaptureError.emptySelection) {
                _ = try ScreenCapture.crop(snapshot, rect: tiny, on: screen)
            }

            // Select the red square in AppKit coordinates (x: 20..70, y: maxY-70..maxY-20).
            let target = NSRect(x: frame.minX + 20, y: frame.maxY - 70, width: 50, height: 50)
            let cropped = try ScreenCapture.crop(snapshot, rect: target, on: screen)
            #expect(cropped.width == 100)
            #expect(cropped.height == 100)
            let pixel = try sampleTopLeftPixel(of: cropped)
            #expect(pixel.r > 200 && pixel.g < 20 && pixel.b < 20)
        }

        private func makeTestSnapshot(width: Int, height: Int) throws -> CGImage {
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try #require(CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return try #require(context.makeImage())
        }

        private func sampleTopLeftPixel(of image: CGImage) throws -> (r: UInt8, g: UInt8, b: UInt8) {
            var pixel = [UInt8](repeating: 0, count: 4)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
            let context = try #require(CGContext(
                data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return (pixel[0], pixel[1], pixel[2])
        }

        private func makePanel(x: CGFloat) -> SelectionPanel {
            let panel = SelectionPanel(
                contentRect: NSRect(x: x, y: 0, width: 100, height: 100),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.alphaValue = 0
            panel.isReleasedWhenClosed = false
            return panel
        }

        private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            ))
        }
    }
}
