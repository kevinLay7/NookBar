import AppKit
import ScreenCaptureKit
import CryptoKit

/// Developer-only research using public window inventory and authorized menu-bar surface capture APIs.
/// Nothing here moves, reveals, activates, or changes a status item. These APIs
/// are deliberately not connected to the production region-capture path.
@MainActor
enum StatusWindowCapture {
    struct Result {
        /// Currently always nil: no public owned-surface mapping has been proven.
        /// Kept for compatibility with the developer diagnostic's result shape.
        let image: CGImage?
        /// JSON-compatible diagnostic data; captures remain in memory.
        let report: [String: Any]
    }

    static func inventory(screen: NSScreen) async -> [String: Any] {
        var report = baseReport(screen: screen)
        do {
            let content = try await shareableContent()
            addInventory(content, to: &report)
            report["inventorySucceeded"] = true
        } catch { addFailure(error, to: &report) }
        return report
    }

    static func captureOwnedStatusItem(_ item: NSStatusItem, screen: NSScreen) async -> Result {
        var report = baseReport(screen: screen)
        report["captureSucceeded"] = false
        report["imageAccepted"] = false
        report["mappingVerified"] = false
        do {
            // Inventory must survive an absent/proxy/non-CG AppKit window.
            let content = try await shareableContent()
            try Task.checkCancellation()
            addInventory(content, to: &report)
            report["inventorySucceeded"] = true
            guard let button = item.button, let ownedWindow = button.window else {
                throw Failure("The owned status item has no AppKit window. Public surface inventory was recorded; no capture was attempted.")
            }
            let number = ownedWindow.windowNumber
            report["directOwnedWindowNumber"] = number
            report["ownedWindowNumberHex"] = "0x" + String(UInt(bitPattern: number), radix: 16)
            report["ownedWindowClass"] = NSStringFromClass(type(of: ownedWindow))
            report["ownedAppKitFrame"] = frameReport(ownedWindow.frame)
            report["ownedButtonBounds"] = frameReport(button.bounds)
            let candidateID = CGWindowID(exactly: number)
            report["exactConversionAvailable"] = candidateID != nil
            report["appKitDeviceNumberIsGlobalIDProven"] = false
            guard number > 0, let candidateID, candidateID != kCGNullWindowID else {
                throw Failure("The owned AppKit window-device number cannot represent a nonzero public CGWindowID. Inventory was recorded. No truncation or replacement window was used.")
            }
            // Apple documents windowNumber as an AppKit window-device number,
            // distinct from the WindowServer global number. Even representable
            // numeric equality plus owner PID cannot authorize window capture.
            let candidates = content.windows.filter { $0.windowID == candidateID }
            report["numericIDShareableCandidateCount"] = candidates.count
            report["numericIDShareableCandidates"] = candidates.map(windowReport)
            throw Failure("An AppKit window-device number is not a verified global SCWindow identity. Independent owned-surface mapping evidence is required before capture; numeric, process, and frame guesses were rejected.")
        } catch {
            addFailure(error, to: &report)
            return Result(image: nil, report: report)
        }
    }

    struct SurfaceResult {
        /// Whole menu-bar surfaces, never attributed to an individual icon.
        let images: [CGWindowID: CGImage]
        let report: [String: Any]
    }

    /// Explicit developer diagnostic for the MenuBarAgent surfaces observed in
    /// the public macOS 27 inventory. It does not capture other owners/layers,
    /// map status items, reveal the menu bar, or open native overflow.
    static func captureMenuBarAgentSurfaces(screen: NSScreen) async -> SurfaceResult {
        var report = baseReport(screen: screen)
        report["route"] = "public SCK whole MenuBarAgent menu-bar surfaces"
        report["individualIconMappingVerified"] = false
        report["transparentIconLayerProven"] = false
        report["offscreenFreshnessProven"] = false
        report["maximumSurfaceCount"] = 6
        report["maximumTotalPixels"] = 12_582_912
        var images: [CGWindowID: CGImage] = [:]
        var results: [[String: Any]] = []
        do {
            guard let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  CGDisplayIsActive(display.uint32Value) != 0 else {
                throw Failure("The requested display is no longer active.")
            }
            let displayBounds = CGDisplayBounds(display.uint32Value)
            let menuHeight = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top,
                                 screen.frame.maxY - screen.visibleFrame.maxY)
            let expectedFrame = CGRect(x: displayBounds.minX, y: displayBounds.minY,
                                       width: displayBounds.width, height: menuHeight)
            report["expectedMenuBarFrame"] = frameReport(expectedFrame)
            guard expectedFrame.width > 0, expectedFrame.width <= 8192,
                  expectedFrame.height > 0, expectedFrame.height <= 256 else {
                throw Failure("The requested menu-bar bounds exceed the diagnostic's capture limit.")
            }
            let content = try await shareableContent()
            try Task.checkCancellation()
            addInventory(content, to: &report)
            report["inventorySucceeded"] = true
            let candidates = content.windows.filter {
                $0.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent" &&
                $0.windowLayer == 24 && $0.frame == expectedFrame
            }.sorted { $0.windowID < $1.windowID }
            report["matchingSurfaceCount"] = candidates.count
            guard !candidates.isEmpty else {
                throw Failure("No MenuBarAgent layer-24 surface exactly matches the requested screen's menu-bar bounds.")
            }
            guard candidates.count <= 6 else {
                throw Failure("More than six matching MenuBarAgent surfaces were found; the diagnostic refused an unbounded capture.")
            }
            var totalPixels = 0
            for candidate in candidates {
                var result = windowReport(candidate)
                result["captureSucceeded"] = false
                result["imageAccepted"] = false
                do {
                    try Task.checkCancellation()
                    let source = try await currentMenuBarSurface(candidate, expectedFrame: expectedFrame)
                    result["preCaptureIdentityVerified"] = true
                    result["preCaptureOnScreen"] = source.isOnScreen
                    let filter = SCContentFilter(desktopIndependentWindow: source)
                    let bounds = filter.contentRect
                    let scale = Double(filter.pointPixelScale)
                    result["filterContentRect"] = frameReport(bounds)
                    result["pointPixelScale"] = scale
                    guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                          scale.isFinite, scale > 0 else {
                        throw Failure("The menu-bar surface has invalid capture bounds or pixel scale.")
                    }
                    let width = ceil(Double(bounds.width) * scale), height = ceil(Double(bounds.height) * scale)
                    guard width <= 16_384, height <= 512, width * height <= Double(12_582_912 - totalPixels) else {
                        throw Failure("The menu-bar surface exceeds the remaining diagnostic pixel budget.")
                    }
                    let config = SCStreamConfiguration()
                    config.width = Int(width); config.height = Int(height)
                    // Default backgroundColor is clear. The assign property must
                    // not receive a temporary CGColor with insufficient lifetime.
                    config.shouldBeOpaque = false
                    config.ignoreShadowsSingleWindow = true
                    config.showsCursor = false; config.showMouseClicks = false
                    config.includeChildWindows = false
                    config.captureResolution = .best; config.captureDynamicRange = .SDR
                    result["configuration"] = ["defaultClearBackground": true, "shouldBeOpaque": false,
                                               "ignoreShadowsSingleWindow": true, "includeChildWindows": false,
                                               "showsCursor": false, "captureResolution": "best", "dynamicRange": "SDR"]
                    result["requestedPixelWidth"] = config.width
                    result["requestedPixelHeight"] = config.height
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    try Task.checkCancellation()
                    result["captureSucceeded"] = true
                    result["imageWidth"] = image.width; result["imageHeight"] = image.height
                    result["sourceAlphaInfo"] = image.alphaInfo.rawValue
                    guard image.width == config.width, image.height == config.height else {
                        throw Failure("The captured surface dimensions differ from the requested dimensions.")
                    }
                    let after = try await currentMenuBarSurface(source, expectedFrame: expectedFrame)
                    result["postCaptureIdentityVerified"] = true
                    result["postCaptureOnScreen"] = after.isOnScreen
                    result["pixels"] = try pixelMetrics(image)
                    totalPixels += image.width * image.height
                    images[source.windowID] = image
                    result["imageAccepted"] = true
                } catch { addFailure(error, to: &result) }
                results.append(result)
                if Task.isCancelled { throw CancellationError() }
            }
            report["acceptedPixelCount"] = totalPixels
        } catch { addFailure(error, to: &report) }
        report["surfaces"] = results
        report["acceptedSurfaceCount"] = images.count
        report["failedSurfaceCount"] = results.filter { ($0["imageAccepted"] as? Bool) != true }.count
        return SurfaceResult(images: images, report: report)
    }

    /// SC and CG independently confirm the exact inventory-authorized tuple.
    /// This is a menu-bar surface identity, not an individual status-item mapping.
    private static func currentMenuBarSurface(_ original: SCWindow, expectedFrame: CGRect) async throws -> SCWindow {
        try Task.checkCancellation()
        let content = try await shareableContent()
        try Task.checkCancellation()
        let matches = content.windows.filter { $0.windowID == original.windowID }
        guard matches.count == 1, let current = matches.first,
              current.owningApplication?.bundleIdentifier == "com.apple.MenuBarAgent",
              current.owningApplication?.processID == original.owningApplication?.processID,
              current.windowLayer == 24, current.frame == original.frame, current.frame == expectedFrame else {
            throw Failure("The MenuBarAgent surface ID, owner, layer, or bounds changed during capture.")
        }
        let metadata = cgWindows().filter { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == original.windowID }
        guard metadata.count == 1, let info = metadata.first,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == current.owningApplication?.processID,
              (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 24,
              let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let frame = CGRect(dictionaryRepresentation: dictionary as CFDictionary), frame == expectedFrame else {
            throw Failure("Public CGWindow metadata no longer confirms the exact MenuBarAgent menu-bar surface.")
        }
        return current
    }

    private static func pixelMetrics(_ image: CGImage) throws -> [String: Any] {
        let count = image.width * image.height
        guard count > 0, count <= 12_582_912 else { throw Failure("The surface exceeds the pixel-analysis limit.") }
        var rgba = [UInt8](repeating: 0, count: count * 4)
        var transparent = 0, partial = 0, opaque = 0
        let inspected = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            for pixel in 0..<count {
                switch bytes[pixel * 4 + 3] {
                case 0: transparent += 1
                case 255: opaque += 1
                default: partial += 1
                }
            }
            return true
        }
        guard inspected else { throw Failure("The menu-bar surface's pixels could not be inspected.") }
        let hash = SHA256.hash(data: Data(rgba)).map { String(format: "%02x", $0) }.joined()
        return ["pixelCount": count, "transparentPixels": transparent, "partialAlphaPixels": partial,
                "opaquePixels": opaque, "nonTransparentPixels": partial + opaque,
                "transparentFraction": Double(transparent) / Double(count), "rgbaSHA256": hash]
    }

    private static func shareableContent() async throws -> SCShareableContent {
        // Avoid a permission prompt as a side effect of this read-only probe.
        guard CGPreflightScreenCaptureAccess() else {
            throw Failure("Screen Recording access is not currently granted; the diagnostic did not request it.")
        }
        return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
    }

    private static func baseReport(screen: NSScreen) -> [String: Any] {
        ["route": "public ScreenCaptureKit inventory; capture requires independent owned-surface mapping",
         "screenRecordingGrantedAtStart": CGPreflightScreenCaptureAccess(),
         "requestedScreenNumber": (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0,
         "requestedScreenFrame": frameReport(screen.frame),
         "requestedScreenBackingScale": screen.backingScaleFactor,
         "processID": ProcessInfo.processInfo.processIdentifier,
         "foreignWindowGuessesAllowed": false, "visibilityMutationRequested": false,
         "lifetimeIsolationProven": false]
    }

    private static func addInventory(_ content: SCShareableContent, to report: inout [String: Any]) {
        let windows = content.windows.sorted { $0.windowID < $1.windowID }
        report["shareableWindowCount"] = windows.count
        report["shareableWindows"] = windows.map(windowReport)
        report["shareableDisplays"] = content.displays.map {
            ["id": $0.displayID, "width": $0.width, "height": $0.height, "frame": frameReport($0.frame)] as [String: Any]
        }
        // Metadata only: no arbitrary foreign windows are captured. Titles are
        // omitted because they are unnecessary for proving direct-ID mapping.
        report["cgWindows"] = cgWindows().map { window -> [String: Any] in
            var value: [String: Any] = [:]
            for key in [kCGWindowNumber, kCGWindowOwnerPID, kCGWindowLayer, kCGWindowIsOnscreen] {
                if let metadata = window[key as String] { value[key as String] = metadata }
            }
            if let bounds = window[kCGWindowBounds as String] { value["bounds"] = bounds }
            return value
        }
    }

    private static func cgWindows() -> [[String: Any]] {
        CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    }
    private static func windowReport(_ window: SCWindow) -> [String: Any] {
        ["id": window.windowID, "ownerPID": window.owningApplication?.processID ?? -1,
         "ownerBundle": window.owningApplication?.bundleIdentifier ?? "",
         "layer": window.windowLayer, "onScreen": window.isOnScreen, "frame": frameReport(window.frame)]
    }
    private static func frameReport(_ frame: CGRect) -> [String: Double] {
        ["x": Double(frame.minX), "y": Double(frame.minY), "width": Double(frame.width), "height": Double(frame.height)]
    }
    private static func addFailure(_ error: Error, to report: inout [String: Any]) {
        let value = error as NSError
        report["error"] = error.localizedDescription
        report["errorDomain"] = value.domain
        report["errorCode"] = value.code
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
