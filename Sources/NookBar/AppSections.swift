import Foundation
@preconcurrency import NativeMenuBar

// App assignments remain the fallback while per-icon overrides are integrated
// with the divider backend. Descriptor keys do not prove lifetime or uniqueness.
@MainActor
final class AppSections {
    enum Section: String, CaseIterable {
        case visible, hidden, alwaysHidden
        var title: String {
            switch self {
            case .visible: "Visible"
            case .hidden: "Hidden"
            case .alwaysHidden: "Always Hidden"
            }
        }
    }
    private let defaults: UserDefaults
    private var iconOverrides: [String: String]
    private var iconProcesses: [String: String]
    var hasIconAssignments: Bool { !iconOverrides.isEmpty }
    func hasIconAssignments(for bundle: String) -> Bool {
        iconOverrides.keys.contains { Self.keyBundle($0) == bundle }
    }
    private(set) var hidden: Set<String>
    private(set) var alwaysHidden: Set<String>
    var tucked: Set<String> { hidden.union(alwaysHidden) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        iconOverrides = (defaults.dictionary(forKey: "IconSections") as? [String: String] ?? [:]).filter { Self.keyBundle($0.key) != nil && Section(rawValue: $0.value) != nil }
        iconProcesses = defaults.dictionary(forKey: "IconSectionProcesses") as? [String: String] ?? [:]
        func valid(_ bundle: String) -> Bool { !bundle.isEmpty && !bundle.hasPrefix("com.apple.") && bundle != "com.codenest.nookbar" }
        alwaysHidden = Set((defaults.stringArray(forKey: "AlwaysHiddenApps") ?? []).filter(valid))
        hidden = Set((defaults.stringArray(forKey: "HiddenApps") ?? []).filter(valid)).subtracting(alwaysHidden)
    }
    func section(for bundle: String) -> Section {
        if alwaysHidden.contains(bundle) { return .alwaysHidden }
        return hidden.contains(bundle) ? .hidden : .visible
    }
    // A retained descriptor alone cannot establish a current unique membership.
    func section(for entry: NBMenuBarEntry) -> Section {
        section(forIconKey: nil, bundle: entry.bundle)
    }
    // AppKit rendering must use snapshot-only matching to avoid reentrant AX
    // queries while another app is synchronously asking us to draw its table.
    func section(for entry: NBMenuBarEntry, among entries: [NBMenuBarEntry], checkCurrent: Bool = true) -> Section {
        let key = NBMenuBarEntryPreferenceKey(entry)
        let unique = iconAssignmentIssue(for: entry, among: entries, checkCurrent: checkCurrent) == nil
        return section(forIconKey: key, bundle: entry.bundle,
                       processKey: unique ? NBMenuBarEntryProcessKey(entry) : nil,
                       inventoryKeys: entries.compactMap { (!checkCurrent || NBMenuBarEntryPreferenceKeyIsCurrent($0)) ? NBMenuBarEntryPreferenceKey($0) : nil })
    }
    func section(forIconKey key: String?, bundle: String, processKey: String? = nil,
                 inventoryKeys: [String] = []) -> Section {
        if let key, Self.keyBundle(key) == bundle, let processKey,
           iconProcesses[key] == processKey, inventoryKeys.filter({ $0 == key }).count == 1,
           let raw = iconOverrides[key], let section = Section(rawValue: raw) { return section }
        // An unassigned sibling can inherit the app choice only while every
        // independent choice still resolves uniquely in this owner process.
        let assignedKeys = iconOverrides.keys.filter { Self.keyBundle($0) == bundle }
        if !assignedKeys.isEmpty {
            guard let key, Self.keyBundle(key) == bundle, inventoryKeys.filter({ $0 == key }).count == 1,
                  let processKey, assignedKeys.allSatisfy({ assignedKey in
                iconProcesses[assignedKey] == processKey && inventoryKeys.filter { $0 == assignedKey }.count == 1
            }) else { return .visible }
        }
        return section(for: bundle)
    }
    func iconAssignmentIssue(for entry: NBMenuBarEntry, among entries: [NBMenuBarEntry], checkCurrent: Bool = true) -> String? {
        guard let key = NBMenuBarEntryPreferenceKey(entry) else { return "This icon has no usable identity label." }
        guard Self.validBundle(entry.bundle) else { return "System and NookBar controls cannot be assigned." }
        guard NBMenuBarEntryProcessKey(entry) != nil else { return "This icon has no verified running process identity." }
        guard !checkCurrent || NBMenuBarEntryPreferenceKeyIsCurrent(entry) else { return "This icon's identity label changed. Refresh before assigning it." }
        let matches = entries.filter { NBMenuBarEntryPreferenceKey($0) == key }
        guard matches.count == 1 else { return "This icon's identity label is shared or missing from the current inventory." }
        guard NBSameMenuBarEntryDescriptor(entry, matches[0]) else { return "This icon changed. Refresh the inventory before assigning it." }
        return nil
    }
    func iconSectionOverride(for entry: NBMenuBarEntry, among entries: [NBMenuBarEntry]) -> Section? {
        guard let key = NBMenuBarEntryPreferenceKey(entry),
              let raw = iconOverrides[key] else { return nil }
        return Section(rawValue: raw)
    }
    @discardableResult
    func assignIcon(_ entry: NBMenuBarEntry, among entries: [NBMenuBarEntry], to section: Section?) -> Bool {
        guard iconAssignmentIssue(for: entry, among: entries) == nil,
              let key = NBMenuBarEntryPreferenceKey(entry), let process = NBMenuBarEntryProcessKey(entry) else { return false }
        assignIcon(key: key, to: section, processKey: process)
        return true
    }
    func assignIcon(key: String, to section: Section?, processKey: String? = nil) {
        guard Self.keyBundle(key) != nil else { return }
        iconOverrides[key] = section?.rawValue
        iconProcesses[key] = section == nil ? nil : processKey
        if iconOverrides.isEmpty {
            defaults.removeObject(forKey: "IconSections")
            defaults.removeObject(forKey: "IconSectionProcesses")
        } else {
            defaults.set(iconOverrides, forKey: "IconSections")
            defaults.set(iconProcesses, forKey: "IconSectionProcesses")
        }
    }
    func partitions(for entries: [NBMenuBarEntry]) -> [Section: [NBMenuBarEntry]] {
        Dictionary(grouping: entries) { section(for: $0, among: entries) }
    }
    private static func validBundle(_ bundle: String) -> Bool {
        !bundle.isEmpty && !bundle.hasPrefix("com.apple.") && bundle != "com.codenest.nookbar"
    }
    private static func keyBundle(_ key: String) -> String? {
        guard let data = key.data(using: .utf8),
              let parts = try? JSONSerialization.jsonObject(with: data) as? [String],
              parts.count == 3, validBundle(parts[0]),
              ["identifier", "description", "title", "help"].contains(parts[1]),
              !parts[2].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return parts[0]
    }
    func bundles(in section: Section) -> Set<String> {
        switch section {
        case .visible: []
        case .hidden: hidden
        case .alwaysHidden: alwaysHidden
        }
    }
    func assign(_ bundle: String, to section: Section) {
        guard !bundle.isEmpty, !bundle.hasPrefix("com.apple."), bundle != "com.codenest.nookbar" else { return }
        hidden.remove(bundle); alwaysHidden.remove(bundle)
        if section == .hidden { hidden.insert(bundle) }
        if section == .alwaysHidden { alwaysHidden.insert(bundle) }
        save()
    }
    func hideAll(_ bundles: Set<String>) {
        for bundle in bundles where section(for: bundle) != .alwaysHidden { assign(bundle, to: .hidden) }
    }
    func clear() {
        hidden.removeAll(); alwaysHidden.removeAll(); iconOverrides.removeAll(); iconProcesses.removeAll()
        defaults.removeObject(forKey: "IconSections"); defaults.removeObject(forKey: "IconSectionProcesses"); save()
    }
    private func save() {
        defaults.set(hidden.sorted(), forKey: "HiddenApps")
        defaults.set(alwaysHidden.sorted(), forKey: "AlwaysHiddenApps")
    }
}
