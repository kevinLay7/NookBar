import Foundation

// The current native backend controls one app's icons together. Section storage
// preserves that constraint; independent per-icon membership remains a parity task.
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
    private(set) var hidden: Set<String>
    private(set) var alwaysHidden: Set<String>
    var tucked: Set<String> { hidden.union(alwaysHidden) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func valid(_ bundle: String) -> Bool { !bundle.isEmpty && !bundle.hasPrefix("com.apple.") && bundle != "com.codenest.nookbar" }
        alwaysHidden = Set((defaults.stringArray(forKey: "AlwaysHiddenApps") ?? []).filter(valid))
        hidden = Set((defaults.stringArray(forKey: "HiddenApps") ?? []).filter(valid)).subtracting(alwaysHidden)
    }
    func section(for bundle: String) -> Section {
        if alwaysHidden.contains(bundle) { return .alwaysHidden }
        return hidden.contains(bundle) ? .hidden : .visible
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
    func clear() { hidden.removeAll(); alwaysHidden.removeAll(); save() }
    private func save() {
        defaults.set(hidden.sorted(), forKey: "HiddenApps")
        defaults.set(alwaysHidden.sorted(), forKey: "AlwaysHiddenApps")
    }
}
