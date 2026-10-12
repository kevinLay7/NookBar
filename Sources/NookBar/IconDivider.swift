import AppKit
@preconcurrency import NativeMenuBar

@MainActor
final class IconDivider {
    struct Failure: LocalizedError {
        let stage: String
        let reason: Error
        var errorDescription: String? { "\(stage): \(reason.localizedDescription)" }
    }
    private var item: NSStatusItem?
    private let movement = MenuBarMovement()
    private var generation = 0
    private var applying = false
    var isBusy: Bool { applying }
    private var originalOrder: [NBMenuBarEntry] = []
    private var movedEntries: [NBMenuBarEntry] = []
    private var orderScreen: NSScreen?
    private var protectedEntries: [NBMenuBarEntry] = []
    private var hiddenEntries: [NBMenuBarEntry] = []
    private var screenFrame: CGRect?
    private var positioningOverflowFrame: CGRect?
    private var ownedControls: [NSStatusItem] = []
    private var appFallbackBundles: Set<String> = []
    private var transactionFallbackBundles: Set<String> = []
    private(set) var active = false
    private(set) var width: CGFloat = 0
    private(set) var stage = "idle"
    private(set) var observations: [[String: Any]] = []

    // Synchronous reveal also releases an interrupted native drag. Order rollback
    // needs native gestures and is available separately for awaited recovery.
    func restore() {
        generation += 1
        movement.cancel()
        if let frame = positioningOverflowFrame, NBMenuBarOverflowState(frame) == 1 {
            _ = NBSetMenuBarOverflowExpanded(frame, false)
        }
        positioningOverflowFrame = nil
        ownedControls = []
        appFallbackBundles = []
        if let item { NSStatusBar.system.removeStatusItem(item) }
        item = nil
        active = false
        width = 0
        protectedEntries = []
        hiddenEntries = []
        screenFrame = nil
        stage = "idle"
    }

    func restoreArrangement() async throws {
        try await waitUntilIdle()
        applying = true
        defer { applying = false }
        try await restoreOriginalOrder()
    }

    private func restoreOriginalOrder() async throws {
        restore()
        guard let screen = orderScreen, !originalOrder.isEmpty else { return }
        let request = generation
        try await Task.sleep(for: .milliseconds(500))
        guard request == generation else { throw CancellationError() }
        let frame = HiddenBar.captureFrame(for: screen)
        // Roll back only foreign items actually moved by this transaction. An
        // untouched predecessor need not be dragged to repair a moved successor.
        for original in movedEntries.reversed() {
            try Task.checkCancellation()
            guard request == generation else { throw CancellationError() }
            func sameSource(_ first: NBMenuBarEntry, _ second: NBMenuBarEntry) -> Bool {
                transactionFallbackBundles.contains(original.bundle) ? NBSameMenuBarEntry(first, second) : NBSameMenuBarEntryDescriptor(first, second)
            }
            guard let index = originalOrder.firstIndex(where: { sameSource($0, original) }) else { continue }
            let entries = NBMenuBarEntries(frame)
            let sources = entries.filter { sameSource($0, original) }
            guard sources.count == 1 else { throw Failure(stage: "restore order", reason: MenuBarMovement.Failure.changed) }
            // An anchor is observed, never moved: a dynamic label may change
            // without changing its validated owner/AX identity or visible pixels.
            func anchor(_ entry: NBMenuBarEntry) -> NBMenuBarEntry? {
                let matches = entries.filter { NBSameMenuBarEntry($0, entry) && NBMenuBarEntryIsExposed($0) }
                return matches.count == 1 ? matches[0] : nil
            }
            let successor = originalOrder.dropFirst(index + 1).compactMap(anchor).first
            let predecessor = originalOrder.prefix(index).reversed().compactMap(anchor).first
            guard let target = successor ?? predecessor else { continue }
            let before = successor != nil
            let foreign = entries.filter { $0.bundle != Bundle.main.bundleIdentifier && NBSameMenuBarEntry($0, $0) }
            let sourcePosition = foreign.firstIndex(where: { sameSource($0, sources[0]) })
            let targetPosition = foreign.firstIndex(where: { NBSameMenuBarEntry($0, target) })
            guard let sourcePosition, let targetPosition else { throw MenuBarMovement.Failure.changed }
            if sourcePosition != targetPosition + (before ? -1 : 1) {
                try await movement.move(sources[0], beside: target, before: before, screen: screen)
            }
        }
        movedEntries = []
        transactionFallbackBundles = []
        originalOrder = []
        orderScreen = nil
    }

    // System extras without launch-date evidence can only be observed here;
    // this fallback never authorizes capture, activation, or native movement.
    private func matches(_ entry: NBMenuBarEntry, in entries: [NBMenuBarEntry]) -> [NBMenuBarEntry] {
        // Retained AppKit objects establish the lifetime of our own controls;
        // adding/removing sibling items can reassign their AX references.
        if entry.bundle == Bundle.main.bundleIdentifier,
           ownedControls.contains(where: { $0.button?.accessibilityLabel() == entry.label }) {
            return entries.filter { $0.bundle == entry.bundle && $0.label == entry.label }
        }
        if NBSameMenuBarEntry(entry, entry) {
            return entries.filter { NBSameMenuBarEntryDescriptor($0, entry) }
        }
        return entries.filter { $0.bundle == entry.bundle && $0.label == entry.label && NBMenuBarEntryIsExposed($0) }
    }

    // Explicit uniform app defaults can hide any icon in that bundle. Mixed
    // per-icon memberships continue to require their original live key.
    private func hiddenMatches(_ entry: NBMenuBarEntry, in entries: [NBMenuBarEntry]) -> [NBMenuBarEntry] {
        if appFallbackBundles.contains(entry.bundle) { return entries.filter { NBSameMenuBarEntry($0, entry) } }
        return matches(entry, in: entries)
    }

    private func hiddenMembershipIsCurrent(_ entry: NBMenuBarEntry) -> Bool {
        appFallbackBundles.contains(entry.bundle) ? NBSameMenuBarEntry(entry, entry) : NBMenuBarEntryPreferenceKeyIsCurrent(entry)
    }

    // A changing visible label (for example temperature) does not change the
    // pixels we must preserve. This observation never rebinds a section key or
    // authorizes movement/capture, and does not prove same-label lifetime.
    private func protectionMatches(_ entry: NBMenuBarEntry, in entries: [NBMenuBarEntry]) -> [NBMenuBarEntry] {
        if entry.bundle == Bundle.main.bundleIdentifier,
           ownedControls.contains(where: { $0.button?.accessibilityLabel() == entry.label }) {
            return matches(entry, in: entries)
        }
        if NBSameMenuBarEntry(entry, entry) { return entries.filter { NBSameMenuBarEntry($0, entry) } }
        return matches(entry, in: entries)
    }

    @discardableResult
    func validate() -> Bool {
        guard active, let frame = screenFrame,
              NSScreen.screens.contains(where: { HiddenBar.captureFrame(for: $0) == frame }) else {
            restore(); return false
        }
        let current = NBMenuBarEntries(frame)
        func exposed(_ entry: NBMenuBarEntry, protection: Bool) -> Bool? {
            let resolved = protection ? protectionMatches(entry, in: current) : hiddenMatches(entry, in: current)
            guard resolved.count == 1 else { return nil }
            return NBMenuBarEntryIsExposed(resolved[0])
        }
        guard protectedEntries.allSatisfy({ exposed($0, protection: true) == true }),
              hiddenEntries.allSatisfy({ hiddenMembershipIsCurrent($0) && exposed($0, protection: false) == false }), NBMenuBarOverflowState(frame) == 0 else {
            restore(); return false
        }
        return true
    }

    func waitUntilIdle() async throws {
        let deadline = Date().addingTimeInterval(60)
        while applying {
            try Task.checkCancellation()
            guard Date() < deadline else { throw MenuBarMovement.Failure.busy }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    func hide(hidden: [NBMenuBarEntry], visible: [NBMenuBarEntry], screen: NSScreen, ownedControls: [NSStatusItem] = [], appFallbackBundles: Set<String> = []) async throws {
        try await waitUntilIdle()
        applying = true
        defer { applying = false }
        restore()
        self.ownedControls = ownedControls
        self.appFallbackBundles = appFallbackBundles
        let request = generation
        stage = "validate partition"
        observations = []
        guard !hidden.isEmpty, !visible.isEmpty else { throw Failure(stage: stage, reason: MenuBarMovement.Failure.geometry) }
        let frame = HiddenBar.captureFrame(for: screen)
        var initial = NBMenuBarEntries(frame)
        // Removing a wide item schedules native layout asynchronously. Resolve
        // the supplied identities only after contracted layout exposes them.
        for _ in 0..<12 {
            let ready = hidden.allSatisfy { entry in
                let resolved = hiddenMatches(entry, in: initial)
                return resolved.count == 1 && NBMenuBarEntryIsExposed(resolved[0])
            } && visible.allSatisfy { entry in
                let resolved = matches(entry, in: initial)
                return resolved.count == 1 && NBMenuBarEntryIsExposed(resolved[0])
            }
            if ready { break }
            try await Task.sleep(for: .milliseconds(150))
            guard request == generation else { throw CancellationError() }
            initial = NBMenuBarEntries(frame)
        }
        func position(_ entry: NBMenuBarEntry, hidden: Bool = false) throws -> Int {
            let resolved = hidden ? hiddenMatches(entry, in: initial) : matches(entry, in: initial)
            guard resolved.count == 1, NBMenuBarEntryIsExposed(resolved[0]),
                  let index = initial.firstIndex(where: { $0 === resolved[0] }) else {
                throw Failure(stage: "\(stage) (\(entry.label), matches \(resolved.count), exposed \(resolved.first.map { NBMenuBarEntryIsExposed($0) } ?? false))", reason: MenuBarMovement.Failure.changed)
            }
            return index
        }
        let hiddenPositions = try hidden.map { try position($0, hidden: true) }
        guard Set(hiddenPositions).count == hidden.count, hidden.allSatisfy({ !$0.bundle.hasPrefix("com.apple.") && $0.bundle != Bundle.main.bundleIdentifier && NBSameMenuBarEntry($0, $0) && hiddenMembershipIsCurrent($0) }) else {
            throw Failure(stage: stage, reason: MenuBarMovement.Failure.changed)
        }
        _ = try visible.map { try position($0) }
        let tucked = hiddenPositions.sorted().map { initial[$0] }
        let protected = initial.filter { entry in !tucked.contains(where: { NBSameMenuBarEntryDescriptor($0, entry) }) }
        let firstSystem = initial.firstIndex { $0.bundle.hasPrefix("com.apple.") } ?? initial.endIndex
        let candidates = initial.indices.filter { index in
            index <= firstSystem && !hiddenPositions.contains(index) && NBSameMenuBarEntry(initial[index], initial[index])
        }
        let lastLeadingHidden = hiddenPositions.filter { $0 < firstSystem }.max() ?? -1
        let preferredBoundary = lastLeadingHidden < 0 ? candidates.last : candidates.first(where: { $0 > lastLeadingHidden })
        observations.append(["phase": "initial partition", "entries": initial.map {
            ["label": $0.label, "bundle": $0.bundle, "x": $0.frame.minX,
             "width": $0.frame.width, "exposed": NBMenuBarEntryIsExposed($0)] as [String: Any]
        }])
        let unexposed = protected.filter { !NBMenuBarEntryIsExposed($0) }
        guard let boundaryIndex = preferredBoundary ?? candidates.last, unexposed.isEmpty else {
            throw Failure(stage: "\(stage) (unexposed: \(unexposed.map(\.label).joined(separator: ", ")), boundaries: \(candidates.count))", reason: MenuBarMovement.Failure.geometry)
        }
        let boundary = initial[boundaryIndex]
        // Each apply rolls back to its own input order, including any previous
        // successful section arrangement. An explicit diagnostic restore can
        // still roll back the most recent successful apply until the next apply.
        // System items are immutable restoration anchors, never sources:
        // movedEntries records only non-Apple foreign icons.
        originalOrder = initial.filter { $0.bundle != Bundle.main.bundleIdentifier && NBSameMenuBarEntry($0, $0) }
        transactionFallbackBundles = appFallbackBundles
        movedEntries = []
        orderScreen = screen
        var succeeded = false
        defer { if !succeeded && request == generation { restore() } }
        do {
            stage = "arrange partition"
            func track(_ entry: NBMenuBarEntry) {
                if entry.bundle != Bundle.main.bundleIdentifier, !entry.bundle.hasPrefix("com.apple."),
                   !movedEntries.contains(where: { NBSameMenuBarEntryDescriptor($0, entry) }) { movedEntries.append(entry) }
            }
            // Keep the divider target on the exposed right-hand bar. Moving a
            // divider toward an expanded left-of-notch target was rejected by
            // native layout; leading visible items can instead move rightward.
            if boundaryIndex < lastLeadingHidden {
                track(boundary)
                try await movement.move(boundary, beside: initial[lastLeadingHidden], before: false, screen: screen)
            }
            for index in hiddenPositions.sorted() where index >= firstSystem || index > boundaryIndex {
                let entry = initial[index]
                try Task.checkCancellation()
                guard request == generation else { throw CancellationError() }
                track(entry)
                let live = NBMenuBarEntries(frame)
                let anchors = matches(boundary, in: live)
                guard anchors.count == 1 else { throw MenuBarMovement.Failure.changed }
                try await movement.move(entry, beside: anchors[0], before: true, screen: screen)
            }
            let divider = NSStatusBar.system.statusItem(withLength: 24)
            divider.button?.title = "│"
            divider.button?.setAccessibilityLabel("NookBar section divider")
            item = divider
            stage = "find divider"
            try await Task.sleep(for: .milliseconds(700))
            guard request == generation else { throw CancellationError() }
            let sources = NBMenuBarEntries(frame).filter { $0.label == "NookBar section divider" && NBMenuBarEntryIsExposed($0) }
            guard sources.count == 1 else { throw MenuBarMovement.Failure.changed }
            stage = "position divider"
            func record(_ phase: String) {
                observations.append(["phase": phase, "overflow": NBMenuBarOverflowState(frame), "entries": NBMenuBarEntries(frame).map {
                    ["label": $0.label, "bundle": $0.bundle, "x": $0.frame.minX,
                     "width": $0.frame.width, "exposed": NBMenuBarEntryIsExposed($0)] as [String: Any]
                }])
            }
            record("before divider movement")
            // A new 24-point item can overflow the very boundary it must move
            // beside. Borrow native expansion only to expose that exact target.
            let boundaryMatches = matches(boundary, in: NBMenuBarEntries(frame))
            guard boundaryMatches.count == 1 else { throw MenuBarMovement.Failure.changed }
            let currentBoundary = boundaryMatches[0]
            if !NBMenuBarEntryIsExposed(currentBoundary) {
                guard NBMenuBarOverflowState(frame) == 0 else { throw MenuBarMovement.Failure.geometry }
                positioningOverflowFrame = frame
                guard NBSetMenuBarOverflowExpanded(frame, true) else { throw MenuBarMovement.Failure.access }
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    guard request == generation else { throw CancellationError() }
                    if let target = NBResolveMenuBarEntry(boundary, frame), NBMenuBarEntryIsExposed(target), NBMenuBarOverflowState(frame) == 1 { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                record("expanded for divider movement")
            }
            let liveBeforeMove = NBMenuBarEntries(frame)
            let freshSources = liveBeforeMove.filter { $0.label == "NookBar section divider" && NBMenuBarEntryIsExposed($0) }
            let freshBoundaries = matches(boundary, in: liveBeforeMove)
            guard freshSources.count == 1, freshBoundaries.count == 1, NBMenuBarEntryIsExposed(freshBoundaries[0]) else { throw MenuBarMovement.Failure.changed }
            do { try await movement.move(freshSources[0], beside: freshBoundaries[0], before: true, screen: screen) }
            catch MenuBarMovement.Failure.rejected {
                record("divider movement rejected")
                // Collapsed overflow identities can share a frame and sort
                // between physically adjacent controls. Verify the owned divider
                // against actual exposed pixels before rejecting that placement.
                var exposed = NBMenuBarEntries(frame).filter { NBMenuBarEntryIsExposed($0) }
                if !exposed.contains(where: { $0.label == "NookBar section divider" }), NBMenuBarOverflowState(frame) == 0 {
                    positioningOverflowFrame = frame
                    guard NBSetMenuBarOverflowExpanded(frame, true) else { throw MenuBarMovement.Failure.access }
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        guard request == generation else { throw CancellationError() }
                        exposed = NBMenuBarEntries(frame).filter { NBMenuBarEntryIsExposed($0) }
                        if exposed.contains(where: { $0.label == "NookBar section divider" }) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    record("expanded to verify divider order")
                }
                let dividerPositions = exposed.indices.filter { exposed[$0].label == "NookBar section divider" }
                let boundaryPositions = exposed.indices.filter { NBSameMenuBarEntryDescriptor(exposed[$0], boundary) }
                guard dividerPositions.count == 1, boundaryPositions.count == 1,
                      dividerPositions[0] == boundaryPositions[0] - 1 else { throw MenuBarMovement.Failure.rejected }
            }
            record("after divider movement")
            stage = "move visible partition"
            let leadingVisible = initial.indices.filter { $0 < max(boundaryIndex, lastLeadingHidden + 1) && !hiddenPositions.contains($0) }.map { initial[$0] }
            for entry in leadingVisible where !NBSameMenuBarEntryDescriptor(entry, boundary) {
                try Task.checkCancellation()
                guard request == generation else { throw CancellationError() }
                var live = NBMenuBarEntries(frame)
                let sources = matches(entry, in: live)
                guard sources.count == 1 else { throw MenuBarMovement.Failure.changed }
                guard !entry.bundle.hasPrefix("com.apple.") else { throw MenuBarMovement.Failure.geometry }
                if !NBMenuBarEntryIsExposed(sources[0]) {
                    guard NBMenuBarOverflowState(frame) == 0 else { throw MenuBarMovement.Failure.geometry }
                    positioningOverflowFrame = frame
                    guard NBSetMenuBarOverflowExpanded(frame, true) else { throw MenuBarMovement.Failure.access }
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        guard request == generation else { throw CancellationError() }
                        live = NBMenuBarEntries(frame)
                        let exposedSources = matches(entry, in: live)
                        if exposedSources.count == 1, NBMenuBarEntryIsExposed(exposedSources[0]) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    record("expanded for visible \(entry.label)")
                }
                live = NBMenuBarEntries(frame)
                let freshSources = matches(entry, in: live), anchors = matches(boundary, in: live)
                guard freshSources.count == 1, anchors.count == 1 else { throw MenuBarMovement.Failure.changed }
                track(entry)
                try await movement.move(freshSources[0], beside: anchors[0], before: true, screen: screen)
                record("moved visible \(entry.label)")
                if NBMenuBarOverflowState(frame) != 1 { positioningOverflowFrame = nil }
            }
            if positioningOverflowFrame != nil {
                if NBMenuBarOverflowState(frame) == 1 {
                    guard NBSetMenuBarOverflowExpanded(frame, false) else { throw MenuBarMovement.Failure.rejected }
                    for _ in 0..<20 {
                        try Task.checkCancellation()
                        guard request == generation else { throw CancellationError() }
                        if NBMenuBarOverflowState(frame) != 1 { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard NBMenuBarOverflowState(frame) != 1 else { throw MenuBarMovement.Failure.rejected }
                }
                positioningOverflowFrame = nil
                record("collapsed after partition movement")
            }
            stage = "size divider"
            for candidateWidth in stride(from: 24, through: Int(frame.width), by: 24) {
                try Task.checkCancellation()
                guard request == generation, NSScreen.screens.contains(where: { HiddenBar.captureFrame(for: $0) == frame }) else { throw CancellationError() }
                divider.length = CGFloat(candidateWidth)
                try await Task.sleep(for: .milliseconds(500))
                let current = NBMenuBarEntries(frame)
                func exposed(_ entry: NBMenuBarEntry, protection: Bool) throws -> Bool {
                    let resolved = protection ? protectionMatches(entry, in: current) : hiddenMatches(entry, in: current)
                    guard resolved.count == 1, protection || hiddenMembershipIsCurrent(entry) else {
                        throw Failure(stage: "\(stage) (\(entry.label), matches \(resolved.count), protection \(protection))", reason: MenuBarMovement.Failure.changed)
                    }
                    return NBMenuBarEntryIsExposed(resolved[0])
                }
                for entry in protected {
                    guard try exposed(entry, protection: true) else {
                        throw Failure(stage: "preserve visible \(entry.label)", reason: MenuBarMovement.Failure.rejected)
                    }
                }
                let allTucked = try tucked.allSatisfy { try !exposed($0, protection: false) }
                if allTucked && NBMenuBarOverflowState(frame) == 0 {
                    active = true; succeeded = true
                    width = CGFloat(candidateWidth)
                    protectedEntries = protected
                    hiddenEntries = tucked
                    screenFrame = frame
                    stage = "active"
                    return
                }
                if allTucked { throw MenuBarMovement.Failure.rejected }
            }
            throw MenuBarMovement.Failure.rejected
        } catch {
            let failedStage = stage
            // A fresh task performs rollback even when the applying task was
            // canceled. New applies remain blocked until recovery finishes.
            restore()
            do { try await Task { @MainActor in try await self.restoreOriginalOrder() }.value }
            catch { throw Failure(stage: "\(failedStage); order recovery", reason: error) }
            throw Failure(stage: failedStage, reason: error)
        }
    }
}
