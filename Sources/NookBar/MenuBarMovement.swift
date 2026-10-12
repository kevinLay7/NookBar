import AppKit
@preconcurrency import NativeMenuBar

@MainActor
final class MenuBarMovement {
    enum Failure: LocalizedError {
        case busy, access, changed, geometry, rejected
        var errorDescription: String? {
            switch self {
            case .busy: "Another icon is moving. Wait and try again."
            case .access: "Release mouse buttons, Shift, Control, and Option. NookBar also needs Accessibility access."
            case .changed: "This icon changed or disappeared. Refresh the list before moving it."
            case .geometry: "The icon positions are unavailable or overlap. Show the menu bar and refresh."
            case .rejected: "macOS did not place the icon at the requested position. The list has been refreshed."
            }
        }
    }
    private var generation = 0
    private var pendingMouseUp: CGEvent?
    private var pendingReset: CGEvent?
    private(set) var isMoving = false

    static func destination(source: CGRect, target: CGRect, before: Bool, menuBar: CGRect) throws -> CGPoint {
        let values = [source.minX, source.minY, source.width, source.height,
                      target.minX, target.minY, target.width, target.height,
                      menuBar.minX, menuBar.minY, menuBar.width, menuBar.height]
        guard values.allSatisfy(\.isFinite), source.width > 0, source.height > 0,
              target.width > 0, target.height > 0, !source.intersects(target),
              menuBar.contains(source), menuBar.contains(target), abs(source.midY - target.midY) <= 8 else {
            throw Failure.geometry
        }
        let point = CGPoint(x: before ? target.minX - 2 : target.maxX + 2, y: target.midY)
        guard menuBar.contains(point) else { throw Failure.geometry }
        return point
    }

    func cancel() {
        generation += 1
        releaseMouse()
    }
    private func releaseMouse() {
        pendingMouseUp?.post(tap: .cghidEventTap)
        pendingReset?.post(tap: .cghidEventTap)
        pendingMouseUp = nil
        pendingReset = nil
    }
    func move(_ source: NBMenuBarEntry, beside target: NBMenuBarEntry, before: Bool, screen: NSScreen) async throws {
        // Verified owner identity also permits reading system icons. It does
        // not establish that those controls support our native drag protocol.
        guard !source.bundle.hasPrefix("com.apple.") else { throw Failure.rejected }
        guard !isMoving else { throw Failure.busy }
        isMoving = true
        generation += 1
        let request = generation
        defer { releaseMouse(); isMoving = false }
        // A table drop must finish releasing its mouse before we start a native drag.
        try await Task.sleep(for: .milliseconds(120))
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        guard CGPreflightPostEventAccess(),
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              ![56, 58, 59, 60, 61, 62].contains(where: {
                  CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0))
              }) else { throw Failure.access }
        let screenFrame = HiddenBar.captureFrame(for: screen)
        guard NSScreen.screens.contains(where: { HiddenBar.captureFrame(for: $0) == screenFrame }) else { throw Failure.changed }
        let entries = NBMenuBarEntries(screenFrame)
        let sources = entries.filter { NBSameMenuBarEntry($0, source) }
        let targets = entries.filter { NBSameMenuBarEntry($0, target) }
        guard sources.count == 1, targets.count == 1, !NBSameMenuBarEntry(source, target) else { throw Failure.changed }
        let currentSource = sources[0], currentTarget = targets[0]
        let start = CGPoint(x: currentSource.frame.midX, y: currentSource.frame.midY)
        guard NBMenuBarEntryMatchesPoint(currentSource, start),
              NBMenuBarEntryMatchesPoint(currentTarget, CGPoint(x: currentTarget.frame.midX, y: currentTarget.frame.midY)) else { throw Failure.changed }
        let menuBar = NBMenuBarFrameAtPoint(start)
        guard screenFrame.contains(currentSource.frame), screenFrame.contains(currentTarget.frame) else { throw Failure.geometry }
        let end = try Self.destination(source: currentSource.frame, target: currentTarget.frame, before: before, menuBar: menuBar)
        let originalFlags = CGEventSource.flagsState(.hidSystemState)
        guard let eventSource = CGEventSource(stateID: .privateState),
              let down = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDown, mouseCursorPosition: start, mouseButton: .left),
              let up = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseUp, mouseCursorPosition: end, mouseButton: .left) else { throw Failure.access }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        pendingMouseUp = up
        pendingReset = CGEvent(mouseEventSource: eventSource, mouseType: .mouseMoved, mouseCursorPosition: end, mouseButton: .left)
        pendingReset?.flags = originalFlags
        down.post(tap: .cghidEventTap)
        do {
            defer { releaseMouse() }
            try await Task.sleep(for: .milliseconds(100))
            for step in 1...10 {
                try Task.checkCancellation()
                guard request == generation else { throw CancellationError() }
                let fraction = CGFloat(step) / 10
                let point = CGPoint(x: start.x + (end.x - start.x) * fraction,
                                    y: start.y + (end.y - start.y) * fraction)
                guard let drag = CGEvent(mouseEventSource: eventSource, mouseType: .leftMouseDragged,
                                         mouseCursorPosition: point, mouseButton: .left) else { throw Failure.access }
                drag.flags = .maskCommand
                drag.post(tap: .cghidEventTap)
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await Task.sleep(for: .milliseconds(750))
        try Task.checkCancellation()
        guard request == generation else { throw CancellationError() }
        let result = NBMenuBarEntries(screenFrame)
        let sourcePositions = result.indices.filter { NBSameMenuBarEntry(result[$0], source) }
        let targetPositions = result.indices.filter { NBSameMenuBarEntry(result[$0], target) }
        guard sourcePositions.count == 1, targetPositions.count == 1,
              sourcePositions[0] == targetPositions[0] + (before ? -1 : 1) else { throw Failure.rejected }
    }
}
