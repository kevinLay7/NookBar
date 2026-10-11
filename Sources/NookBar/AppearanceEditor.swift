import AppKit
import SwiftUI

struct AppearanceEditor: View {
    @ObservedObject var manager: MenuBarAppearance
    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Use dynamic appearance", isOn: $manager.configuration.dynamic)
                    Text("Apply different colors, borders, and shadows in light and dark mode.").font(.caption).foregroundStyle(.secondary)
                }
                if manager.configuration.dynamic {
                    partial("Light appearance", style: $manager.configuration.light, preview: .light)
                    partial("Dark appearance", style: $manager.configuration.dark, preview: .dark)
                } else { partial("Appearance", style: $manager.configuration.standard) }
                Section("Menu Bar Shape") {
                    Picker("Shape", selection: $manager.configuration.shape) {
                        ForEach(AppearanceConfiguration.Shape.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    if manager.configuration.shape == .full { caps("Full shape", ends: $manager.configuration.full) }
                    if manager.configuration.shape == .split {
                        caps("App menus", ends: $manager.configuration.menus)
                        caps("Icons", ends: $manager.configuration.icons)
                    }
                    if manager.configuration.shape != .none {
                        Toggle("Use inset shape on screens with notch", isOn: $manager.configuration.inset)
                        Text("Shapes restore the wallpaper outside the menu bar. Screen Recording access is required; only its menu bar strip is sampled.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            Divider()
            HStack(alignment: .center, spacing: 12) {
                Text(manager.status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Reset") { manager.preview = nil; manager.configuration = AppearanceConfiguration() }
                    .help("Restore the original menu bar appearance")
            }.padding(12)
        }
        .onDisappear { manager.preview = nil }
    }
    @ViewBuilder private func partial(_ title: String, style: Binding<AppearanceStyle>, preview: MenuBarAppearance.Preview? = nil) -> some View {
        Section {
            Picker("Tint", selection: style.tint) {
                ForEach(AppearanceStyle.Tint.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            if style.wrappedValue.tint == .solid { ColorPicker("Tint Color", selection: color(style.tintColor), supportsOpacity: false) }
            if style.wrappedValue.tint == .gradient {
                ForEach(style.stops) { stop in
                    HStack {
                        ColorPicker("Color Stop", selection: color(stop.color), supportsOpacity: false)
                        Slider(value: stop.location, in: 0...1).accessibilityLabel("Color stop position")
                        TextField("Position", value: stop.location, format: .percent.precision(.fractionLength(0)))
                            .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 64)
                            .accessibilityLabel("Color stop position in percent")
                        Button { style.wrappedValue.stops.removeAll { $0.id == stop.wrappedValue.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove color stop").disabled(style.wrappedValue.stops.count <= 2)
                    }
                }
                Button("Add Color Stop") { style.wrappedValue.stops.append(AppearanceStop(color: AppearanceColor(red: 0.5, green: 0.5, blue: 0.5), location: 0.5)) }
            }
            Toggle("Shadow", isOn: style.shadow)
            Toggle("Border", isOn: style.border)
            if style.wrappedValue.border {
                ColorPicker("Border Color", selection: color(style.borderColor), supportsOpacity: true)
                Picker("Border Width", selection: style.borderWidth) { ForEach(1...3, id: \.self) { Text("\($0) pt").tag(Double($0)) } }
            }
        } header: {
            HStack {
                Text(title)
                if let preview {
                    Spacer()
                    Button("Hold to Preview") {}.buttonStyle(HoldAppearancePreview { manager.preview = $0 ? preview : nil })
                }
            }
        }
    }
    private func color(_ value: Binding<AppearanceColor>) -> Binding<Color> {
        Binding(get: { Color(nsColor: value.wrappedValue.normalized.color) }, set: { value.wrappedValue = AppearanceColor(NSColor($0)) })
    }
    @ViewBuilder private func caps(_ title: String, ends: Binding<AppearanceConfiguration.Ends>) -> some View {
        Picker("\(title) left edge", selection: ends.left) {
            ForEach(AppearanceConfiguration.Cap.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.pickerStyle(.segmented)
        Picker("\(title) right edge", selection: ends.right) {
            ForEach(AppearanceConfiguration.Cap.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }.pickerStyle(.segmented)
    }
}

private struct HoldAppearancePreview: ButtonStyle {
    let pressing: (Bool) -> Void
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(.horizontal, 10).padding(.vertical, 3)
            .background(.quaternary.opacity(configuration.isPressed ? 0.7 : 0.4), in: Capsule())
            .onChange(of: configuration.isPressed) { _, value in pressing(value) }
            .onDisappear { pressing(false) }
    }
}
