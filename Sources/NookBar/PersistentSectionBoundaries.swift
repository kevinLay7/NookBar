import AppKit
@preconcurrency import NativeMenuBar

// Owns persistent physical section markers. Native placement, hiding, migration,
// and restart behavior must be verified by the caller before adopting this layout.
@MainActor
final class PersistentSectionBoundaries {
    enum Boundary: String, CaseIterable {
        case hidden, alwaysHidden
        var autosaveName: String { "NookBar.SectionBoundary.\(rawValue)" }
        var label: String { "NookBar persistent \(rawValue) boundary" }
    }
    enum Failure: LocalizedError {
        case unavailable, expanded, geometry, width, savedLayout, restoration([String])
        var errorDescription: String? {
            switch self {
            case .unavailable: "Persistent section boundaries are missing, ambiguous, or not exposed."
            case .expanded: "Contract section boundaries before reading physical membership."
            case .geometry: "Persistent section boundaries are out of order or overlap."
            case .width: "The requested section width exceeds the current display bounds."
            case .savedLayout: "Saved section positions require arrangement; initialization did not move them."
            case .restoration(let labels): "Section initialization failed to restore foreign item state: \(labels.joined(separator: ", "))."
            }
        }
    }
    struct Layout {
        let hidden: NBMenuBarEntry
        let alwaysHidden: NBMenuBarEntry
        let sections: [AppSections.Section: [NBMenuBarEntry]]
        let unresolved: [NBMenuBarEntry]
    }
    static let contractedWidth: CGFloat = 24
    private let defaults: UserDefaults
    private var items: [Boundary: NSStatusItem] = [:]
    private let movement = MenuBarMovement()
    private var generation = 0
    private var missingPositions: Set<Boundary> = []
    private var creationPreferences: [Boundary: [String: Any]] = [:]
    private var overflowLease: (frame: CGRect, original: Int)?
    private struct ForeignBaseline {
        let frame: CGRect
        let entries: [NBMenuBarEntry]
        let exposed: [Bool]
        let overflow: Int
    }
    struct ForeignRestoration {
        let identitiesResolved: Bool
        let exposureRestored: Bool
        let exposedOrderRestored: Bool
        let overflowRestored: Bool
        let failedLabels: [String]
        var passed: Bool { identitiesResolved && exposureRestored && exposedOrderRestored && overflowRestored }
    }
    private var foreignBaselines: [ForeignBaseline] = []
    private(set) var isInitializing = false
    private(set) var initializationObservations: [[String: Any]] = []
    var controls: [NSStatusItem] { Boundary.allCases.compactMap { items[$0] } }
    var isCreated: Bool { items.count == Boundary.allCases.count }

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // Native autosave restoration owns placement. Never seed/reset preferred
    // positions here; a missing or invalid restored layout requires arrangement.
    func createIfNeeded() {
        guard !isInitializing else { return }
        createItems()
    }

    private func preferenceKeys(for boundary: Boundary) -> [String] {
        ["Preferred Position", "Visible", "VisibleCC"].map { "NSStatusItem \($0) \(boundary.autosaveName)" }
    }

    private func createItems() {
        if items.isEmpty {
            let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
            foreignBaselines = NSScreen.screens.map { screen in
                let frame = HiddenBar.captureFrame(for: screen)
                let entries = NBMenuBarEntries(frame).filter { $0.bundle != own }
                return ForeignBaseline(frame: frame, entries: entries, exposed: entries.map { NBMenuBarEntryIsExposed($0) }, overflow: NBMenuBarOverflowState(frame))
            }
        }
        for boundary in Boundary.allCases where items[boundary] == nil {
            // Follow Ice's create-zero, autosave-name, then-width sequence.
            // This sequence alone does not prove native position restoration.
            let keys = preferenceKeys(for: boundary)
            creationPreferences[boundary] = Dictionary(uniqueKeysWithValues: keys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
            if defaults.object(forKey: keys[0]) == nil { missingPositions.insert(boundary) }
            let item = NSStatusBar.system.statusItem(withLength: 0)
            item.autosaveName = boundary.autosaveName
            item.length = Self.contractedWidth
            item.button?.title = "│"
            item.button?.setAccessibilityLabel(boundary.label)
            items[boundary] = item
        }
    }

    // Observe restoration independently of descriptor text: foreign labels can
    // change during setup. Only originally exposed entries establish order.
    func observeForeignRestoration(on screen: NSScreen) -> ForeignRestoration {
        let frame = HiddenBar.captureFrame(for: screen)
        guard let baseline = foreignBaselines.first(where: { $0.frame == frame }), !baseline.entries.isEmpty else {
            return ForeignRestoration(identitiesResolved: false, exposureRestored: false, exposedOrderRestored: false, overflowRestored: false, failedLabels: ["initial inventory unavailable"])
        }
        let current = NBMenuBarEntries(frame)
        var positions: [Int] = [], failures: [String] = []
        var resolved = true, exposure = true
        for (entry, wasExposed) in zip(baseline.entries, baseline.exposed) {
            let matches = current.indices.filter { NBSameMenuBarEntry(current[$0], entry) }
            guard matches.count == 1 else { resolved = false; failures.append(entry.label); continue }
            let index = matches[0]
            if NBMenuBarEntryIsExposed(current[index]) != wasExposed { exposure = false; failures.append(entry.label) }
            if wasExposed { positions.append(index) }
        }
        let order = resolved && zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
        let overflow = NBMenuBarOverflowState(frame) == baseline.overflow
        if !order { failures.append("foreign order") }
        if !overflow { failures.append("native overflow") }
        return ForeignRestoration(identitiesResolved: resolved, exposureRestored: exposure, exposedOrderRestored: order, overflowRestored: overflow, failedLabels: failures)
    }

    func cancelInitialization() {
        generation += 1
        movement.cancel()
        restoreOverflowState()
    }

    private func restoreOverflowState() {
        guard let lease = overflowLease else { return }
        let state = NBMenuBarOverflowState(lease.frame)
        if lease.original == 0, state == 1 { _ = NBSetMenuBarOverflowExpanded(lease.frame, false) }
        if lease.original == 1, state == 0 { _ = NBSetMenuBarOverflowExpanded(lease.frame, true) }
        overflowLease = nil
    }

    // New markers alone may move. Existing autosaved layouts are never seeded
    // or repaired implicitly. This API is an operation boundary, not a draw API.
    func initializeNewLayout(on screen: NSScreen, anchor: NBMenuBarEntry? = nil) async throws -> Layout {
        guard !isInitializing else { throw MenuBarMovement.Failure.busy }
        isInitializing = true
        defer { isInitializing = false }
        generation += 1
        let request = generation
        initializationObservations = []
        createItems()
        let frame = HiddenBar.captureFrame(for: screen)
        let own = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        let newItems = items.filter { missingPositions.contains($0.key) }
        let newPreferences = creationPreferences.filter { newItems[$0.key] != nil }
        func entries() -> [NBMenuBarEntry] { NBMenuBarEntries(frame) }
        func owned(_ boundary: Boundary, in live: [NBMenuBarEntry]) -> NBMenuBarEntry? {
            let matches = live.filter { $0.bundle == own && $0.label == boundary.label && NBMenuBarEntryIsExposed($0) }
            return matches.count == 1 ? matches[0] : nil
        }
        func resolveAnchor(_ original: NBMenuBarEntry, in live: [NBMenuBarEntry]) -> NBMenuBarEntry? {
            let matches = live.filter { NBSameMenuBarEntry($0, original) && NBMenuBarEntryIsExposed($0) }
            return matches.count == 1 ? matches[0] : nil
        }
        func check() throws {
            try Task.checkCancellation()
            guard request == generation, NSScreen.screens.contains(where: { HiddenBar.captureFrame(for: $0) == frame }) else { throw CancellationError() }
        }
        func record(_ phase: String) {
            initializationObservations.append(["phase": phase, "overflow": NBMenuBarOverflowState(frame), "entries": entries().map {
                ["label": $0.label, "bundle": $0.bundle, "x": $0.frame.minX, "width": $0.frame.width, "exposed": NBMenuBarEntryIsExposed($0)] as [String: Any]
            }])
        }
        func exposeOwned(_ boundary: Boundary) async throws {
            try check()
            if owned(boundary, in: entries()) != nil { return }
            let state = NBMenuBarOverflowState(frame)
            guard state == 0 else { throw Failure.unavailable }
            if overflowLease == nil { overflowLease = (frame, state) }
            guard NBSetMenuBarOverflowExpanded(frame, true) else { throw MenuBarMovement.Failure.access }
            for _ in 0..<20 {
                try check()
                if owned(boundary, in: entries()) != nil, NBMenuBarOverflowState(frame) == 1 { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw Failure.unavailable
        }
        func place(_ boundary: Boundary, beside target: NBMenuBarEntry?, ownedTarget: Boundary?, before: Bool) async throws {
            try check()
            try await exposeOwned(boundary)
            if let ownedTarget { try await exposeOwned(ownedTarget) }
            let live = entries()
            guard let source = owned(boundary, in: live),
                  let target = ownedTarget.flatMap({ owned($0, in: live) }) ?? target.flatMap({ resolveAnchor($0, in: live) }) else { throw Failure.unavailable }
            record("before moving \(boundary.rawValue)")
            do { try await movement.move(source, beside: target, before: before, screen: screen) }
            catch MenuBarMovement.Failure.rejected {
                // Only retained local objects may rebind through their labels.
                // Verify the requested physical adjacency after AX reassignment.
                try await exposeOwned(boundary)
                if let ownedTarget { try await exposeOwned(ownedTarget) }
                let actual = entries().filter { NBMenuBarEntryIsExposed($0) }
                guard let source = owned(boundary, in: actual),
                      let target = ownedTarget.flatMap({ owned($0, in: actual) }) ?? resolveAnchor(target, in: actual),
                      let sourceIndex = actual.firstIndex(where: { $0 === source }),
                      let targetIndex = actual.firstIndex(where: { $0 === target }),
                      sourceIndex == targetIndex + (before ? -1 : 1) else { throw MenuBarMovement.Failure.rejected }
            }
            record("after moving \(boundary.rawValue)")
        }
        do {
            try check()
            try await Task.sleep(for: .milliseconds(700))
            try check()
            guard items.values.allSatisfy({ $0.length == Self.contractedWidth }) else { throw Failure.expanded }
            if let layout = try? readLayout(in: entries(), screenFrame: frame) {
                missingPositions.subtract(newItems.keys)
                record("restored valid contracted markers")
                return layout
            }
            guard !newItems.isEmpty else { throw Failure.savedLayout }
            let initialOverflow = NBMenuBarOverflowState(frame)
            if initialOverflow == 0 || initialOverflow == 1 { overflowLease = (frame, initialOverflow) }
            record("initial contracted markers")
            if newItems.count == Boundary.allCases.count {
                // Prefer a target on the exposed right-hand bar. Foreign targets
                // are immutable; no foreign icon is used as a movement source.
                let live = entries()
                let chosen: NBMenuBarEntry?
                if let anchor {
                    chosen = resolveAnchor(anchor, in: live)
                } else {
                    chosen = live.last { $0.bundle != own && NBMenuBarEntryIsExposed($0) && NBSameMenuBarEntry($0, $0) }
                }
                guard let chosen else { throw Failure.unavailable }
                try await place(.hidden, beside: chosen, ownedTarget: nil, before: true)
                try await place(.alwaysHidden, beside: nil, ownedTarget: .hidden, before: true)
            } else if newItems[.alwaysHidden] != nil {
                try await place(.alwaysHidden, beside: nil, ownedTarget: .hidden, before: true)
            } else {
                try await place(.hidden, beside: nil, ownedTarget: .alwaysHidden, before: false)
            }
            try check()
            restoreOverflowState()
            try await Task.sleep(for: .milliseconds(500))
            try check()
            let layout = try readLayout(in: entries(), screenFrame: frame)
            missingPositions.subtract(newItems.keys)
            record("initialized contracted markers")
            return layout
        } catch {
            let originalError = error
            // Restore exact pre-creation values/absences for new controls only.
            // An existing saved mate is never moved or discarded by this setup.
            movement.cancel()
            restoreOverflowState()
            for (boundary, originalItem) in newItems {
                if let current = items[boundary], current !== originalItem { continue }
                if items[boundary] === originalItem { NSStatusBar.system.removeStatusItem(originalItem) }
                for key in preferenceKeys(for: boundary) {
                    if let value = newPreferences[boundary]?[key] { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
                items.removeValue(forKey: boundary)
                missingPositions.remove(boundary)
            }
            try? await Task { @MainActor in try await Task.sleep(for: .milliseconds(700)) }.value
            let restoration = observeForeignRestoration(on: screen)
            if !restoration.passed { throw Failure.restoration(restoration.failedLabels) }
            throw originalError
        }
    }

    // Contracting retains the same AppKit objects and their physical positions.
    func contract() {
        for item in items.values { item.length = Self.contractedWidth }
    }

    // Width delivery does not prove hiding or preservation of adjacent items.
    // The caller must use bounded exposure observations and restore on failure.
    func setWidth(_ width: CGFloat, for boundary: Boundary, maximum: CGFloat) throws {
        guard let item = items[boundary] else { throw Failure.unavailable }
        guard width.isFinite, maximum.isFinite, maximum >= Self.contractedWidth,
              width >= Self.contractedWidth, width <= maximum else { throw Failure.width }
        item.length = width
    }

    // This is an operation-boundary AX check, never an AppKit table render API.
    func readLayout(in entries: [NBMenuBarEntry], screenFrame: CGRect) throws -> Layout {
        guard isCreated else { throw Failure.unavailable }
        guard items.values.allSatisfy({ $0.length == Self.contractedWidth }) else { throw Failure.expanded }
        let bundle = Bundle.main.bundleIdentifier ?? "com.codenest.nookbar"
        func resolve(_ boundary: Boundary) throws -> NBMenuBarEntry {
            let matches = entries.filter { $0.bundle == bundle && $0.label == boundary.label }
            guard matches.count == 1, CGRectContainsRect(screenFrame, matches[0].frame),
                  NBMenuBarEntryIsExposed(matches[0]) else { throw Failure.unavailable }
            return matches[0]
        }
        let hidden = try resolve(.hidden), alwaysHidden = try resolve(.alwaysHidden)
        guard alwaysHidden.frame.maxX <= hidden.frame.minX,
              alwaysHidden.frame.minY < hidden.frame.maxY, alwaysHidden.frame.maxY > hidden.frame.minY else { throw Failure.geometry }
        var sections: [AppSections.Section: [NBMenuBarEntry]] = [:]
        var unresolved: [NBMenuBarEntry] = []
        for entry in entries where !(entry === hidden || entry === alwaysHidden) {
            guard CGRectContainsRect(screenFrame, entry.frame), NBMenuBarEntryIsExposed(entry),
                  let section = Self.section(for: entry.frame, hidden: hidden.frame, alwaysHidden: alwaysHidden.frame) else {
                unresolved.append(entry); continue
            }
            sections[section, default: []].append(entry)
        }
        return Layout(hidden: hidden, alwaysHidden: alwaysHidden, sections: sections, unresolved: unresolved)
    }

    // Pure geometry for an already validated contracted snapshot. Crossing a
    // marker or another menu-bar row is unresolved, regardless of icon labels.
    static func section(for frame: CGRect, hidden: CGRect, alwaysHidden: CGRect) -> AppSections.Section? {
        guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0,
              !hidden.isNull, !hidden.isInfinite, !alwaysHidden.isNull, !alwaysHidden.isInfinite,
              hidden.width > 0, hidden.height > 0, alwaysHidden.width > 0, alwaysHidden.height > 0,
              alwaysHidden.maxX <= hidden.minX,
              frame.minY < hidden.maxY, frame.maxY > hidden.minY,
              frame.minY < alwaysHidden.maxY, frame.maxY > alwaysHidden.minY else { return nil }
        if frame.minX >= hidden.maxX { return .visible }
        if frame.maxX <= alwaysHidden.minX { return .alwaysHidden }
        if frame.minX >= alwaysHidden.maxX && frame.maxX <= hidden.minX { return .hidden }
        return nil
    }

    // Removal can erase AppKit's position preference. Preserve only our own
    // control keys; explicit reset discards them. Launch never rewrites them.
    func dispose(preservingPositions: Bool = true) {
        cancelInitialization()
        for (boundary, item) in items {
            let keys = preferenceKeys(for: boundary)
            let saved = keys.map { key in (key, defaults.object(forKey: key)) }
            NSStatusBar.system.removeStatusItem(item)
            if preservingPositions {
                for (key, value) in saved {
                    if let value { defaults.set(value, forKey: key) }
                    else { defaults.removeObject(forKey: key) }
                }
            } else {
                for key in keys { defaults.removeObject(forKey: key) }
            }
        }
        items.removeAll()
        missingPositions.removeAll()
        creationPreferences.removeAll()
    }
}
