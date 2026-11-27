import SwiftData
import SwiftUI

/// The Settings window: a sidebar of sections and the selected section's pane, laid out like Trellis's.
struct SettingsView: View {
    @State private var selection: SettingsSection = .appearance

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Theme.hairline).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(selection.title).font(.system(size: 22, weight: .semibold))
                    Text(selection.detail).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 18)
                HairlineDivider().padding(.horizontal, 28)
                Group {
                    switch selection {
                    case .general: GeneralSettingsView()
                    case .appearance: AppearanceSettingsView()
                    case .remoteAgent: RemoteAgentSettingsView()
                    }
                }
                .padding(.horizontal, 8)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.canvas)
        }
        .frame(minWidth: 780, idealWidth: 820, minHeight: 600, idealHeight: 700)
        .navigationTitle(selection.title)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("SETTINGS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 20).padding(.bottom, 10)
            ForEach(SettingsSection.allCases) { section in
                let isSelected = selection == section
                Button {
                    selection = section
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.symbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(section.tileColor, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .accessibilityHidden(true)
                        Text(section.title)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 200)
        .frame(maxHeight: .infinity)
        .background(Theme.listBackground)
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, remoteAgent
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .remoteAgent: "Remote Agent"
        }
    }
    var detail: String {
        switch self {
        case .general: "Defaults for new requests, and how much history PostWoman keeps."
        case .appearance: "Choose light, dark or the macOS setting, and the themes and accent PostWoman uses."
        case .remoteAgent: "Let agents such as Claude Code work with your collections, requests and history over MCP."
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "circle.lefthalf.filled"
        case .remoteAgent: "antenna.radiowaves.left.and.right"
        }
    }
    @MainActor var tileColor: Color {
        switch self {
        case .general: Color(nsColor: .systemGray)
        case .appearance: Color.appAccent
        case .remoteAgent: Color(nsColor: .systemIndigo)
        }
    }
}

// MARK: - Shared rows

/// A row's label with its help text underneath.
struct SettingsLabel: View {
    let title: String
    var help: String?
    init(_ title: String, help: String? = nil) {
        self.title = title
        self.help = help
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let help {
                Text(help).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension View {
    /// A grouped form over the pane's own background.
    func settingsFormStyle() -> some View { formStyle(.grouped).scrollContentBackground(.hidden) }
}

// MARK: - General

/// Request defaults and history retention.
struct GeneralSettingsView: View {
    /// The default timeout in seconds for HTTP requests, persisted across app launches.
    @AppStorage("defaultTimeout") private var defaultTimeout: Double = 30.0
    @AppStorage(HistoryRetention.limitKey) private var historyLimit = HistoryRetention.defaultLimit
    @Environment(\.modelContext) private var modelContext
    @Query private var history: [RequestHistory]
    @State private var isConfirmingClear = false

    var body: some View {
        Form {
            Section("Request defaults") {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Timeout", value: $defaultTimeout, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .textFieldStyle(.themed)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                } label: {
                    SettingsLabel("Default timeout", help: "How long a new request waits for a response before it fails.")
                }
            }
            Section("History") {
                LabeledContent {
                    HStack(spacing: 6) {
                        TextField("Maximum entries", value: $historyLimit, format: .number)
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 70)
                            .textFieldStyle(.themed)
                        Text("entries").foregroundStyle(.secondary)
                    }
                } label: {
                    SettingsLabel(
                        "Maximum entries",
                        help: "PostWoman keeps the most recent requests and deletes older ones. The default is \(HistoryRetention.defaultLimit).")
                }
                LabeledContent {
                    Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                        .disabled(history.isEmpty)
                } label: {
                    SettingsLabel(
                        "Clear history",
                        help: history.count == 1 ? "1 entry in History." : "\(history.count) entries in History.")
                }
            }
        }
        .settingsFormStyle()
        .onChange(of: historyLimit) { _, limit in
            let clamped = min(max(limit, HistoryRetention.limitRange.lowerBound), HistoryRetention.limitRange.upperBound)
            if clamped != limit {
                historyLimit = clamped
            } else {
                HistoryRetention.trim(modelContext, limit: clamped)
            }
        }
        .confirmationDialog("Clear all history?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) { HistoryRetention.clear(modelContext) }
        } message: {
            Text("This deletes every entry in History. Saved requests are not affected.")
        }
    }
}

// MARK: - Appearance

/// Mode, light and dark themes, accent and code text size. Changes apply at once.
struct AppearanceSettingsView: View {
    @Bindable private var store = ThemeStore.shared

    var body: some View {
        Form {
            Section("Window") {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsLabel(
                        "Application appearance",
                        help: "Follow macOS, or keep PostWoman always light or always dark. Each mode uses the theme picked below.")
                    AppearanceModePicker(selection: $store.mode, light: store.light, dark: store.dark, accent: store.accent)
                }
                .padding(.vertical, 4)
                ThemePicker(
                    title: "Light theme", help: "Used in Light mode, and in System mode while macOS is light.",
                    themes: ThemePalette.lightThemes, selection: $store.lightThemeID, accent: store.accent)
                ThemePicker(
                    title: "Dark theme", help: "Used in Dark mode, and in System mode while macOS is dark.",
                    themes: ThemePalette.darkThemes, selection: $store.darkThemeID, accent: store.accent)
            }
            Section("Accent") {
                LabeledContent {
                    AccentPicker(selection: $store.accent, light: store.light, dark: store.dark)
                } label: {
                    SettingsLabel("Accent color", help: "The Send button, selected tabs, selection and focus rings. Theme uses each theme's own accent.")
                }
            }
            Section("Code text") {
                Stepper(value: $store.codeFontSize, in: ThemeStore.codeFontSizeRange, step: 1) {
                    SettingsLabel(
                        "Font size: \(Int(store.codeFontSize)) pt", help: "The request body, the response body and their line numbers.")
                }
                CodeSample(fontSize: store.codeFontSize)
            }
        }
        .settingsFormStyle()
    }
}

/// A tile per mode showing a small PostWoman window in the theme it uses; System is split between the two.
struct AppearanceModePicker: View {
    @Binding var selection: AppearanceMode
    let light: ThemePalette
    let dark: ThemePalette
    let accent: AccentChoice

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(AppearanceMode.allCases) { mode in tile(mode) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Application appearance")
    }

    private func themeNames(_ mode: AppearanceMode) -> String {
        switch mode {
        case .system: "\(light.name) · \(dark.name)"
        case .light: light.name
        case .dark: dark.name
        }
    }

    private func tile(_ mode: AppearanceMode) -> some View {
        let isSelected = mode == selection
        return Button {
            selection = mode
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    ThemeMiniWindow(palette: mode == .dark ? dark : light, accent: accent)
                    if mode == .system { ThemeMiniWindow(palette: dark, accent: accent).clipShape(DiagonalHalf()) }
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(isSelected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(Theme.hairline), lineWidth: isSelected ? 3 : 1)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(mode.title).fontWeight(isSelected ? .semibold : .regular)
                    Text(themeNames(mode)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.leading, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.title)
        .accessibilityValue(themeNames(mode))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A grid of theme swatches for one appearance.
private struct ThemePicker: View {
    let title: String
    let help: String
    let themes: [ThemePalette]
    @Binding var selection: String
    let accent: AccentChoice

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsLabel(title, help: help)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(themes) { theme in
                    ThemeSwatch(palette: theme, accent: accent, isSelected: theme.id == selection) { selection = theme.id }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

private struct ThemeSwatch: View {
    let palette: ThemePalette
    let accent: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Color(nsColor: NSColor(hex: palette.sidebar)).frame(width: 22)
                    VStack(alignment: .leading, spacing: 3) {
                        bar(palette.key, width: 34)
                        bar(palette.string, width: 24)
                        HStack(spacing: 3) {
                            bar(palette.number, width: 14)
                            Capsule().fill(Color(nsColor: NSColor(hex: accent.hex(in: palette)))).frame(width: 12, height: 5)
                        }
                    }
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .background(Color(nsColor: NSColor(hex: palette.background)))
                }
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(Color(nsColor: NSColor(hex: palette.border))))
                Text(palette.name).font(.caption).fontWeight(isSelected ? .semibold : .regular).lineLimit(1)
            }
            .padding(6)
            .contentShape(Rectangle())
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? AnyShapeStyle(Color.appAccent) : AnyShapeStyle(Theme.hairline), lineWidth: isSelected ? 2 : 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(palette.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func bar(_ hex: UInt32, width: CGFloat) -> some View {
        Capsule().fill(Color(nsColor: NSColor(hex: hex))).frame(width: width, height: 3)
    }
}

/// A swatch per accent color; Theme shows the light and dark themes' own accents side by side.
private struct AccentPicker: View {
    @Binding var selection: AccentChoice
    let light: ThemePalette
    let dark: ThemePalette

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AccentChoice.allCases) { choice in
                let isSelected = choice == selection
                Button {
                    selection = choice
                } label: {
                    ZStack {
                        Circle().fill(Color(nsColor: NSColor(hex: choice.hex(in: light))))
                        if choice == .theme {
                            Circle().fill(Color(nsColor: NSColor(hex: choice.hex(in: dark)))).clipShape(DiagonalHalf())
                        }
                    }
                    .frame(width: 18, height: 18)
                    .padding(3)
                    .overlay(Circle().strokeBorder(isSelected ? Color.primary.opacity(0.7) : .clear, lineWidth: 2))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(choice.title)
                .accessibilityLabel(choice.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
            Text(selection.title).font(.subheadline).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accent color")
    }
}

/// A few lines of JSON in the code font and the current theme's syntax colors.
private struct CodeSample: View {
    let fontSize: Double

    private var sample: AttributedString {
        let parts: [(String, Color)] = [
            ("{\n  ", Theme.syntax(\.punctuation)), ("\"id\"", Theme.syntax(\.key)), (": ", Theme.syntax(\.punctuation)),
            ("42", Theme.syntax(\.number)), (",\n  ", Theme.syntax(\.punctuation)), ("\"name\"", Theme.syntax(\.key)),
            (": ", Theme.syntax(\.punctuation)), ("\"Ada Lovelace\"", Theme.syntax(\.string)), (",\n  ", Theme.syntax(\.punctuation)),
            ("\"active\"", Theme.syntax(\.key)), (": ", Theme.syntax(\.punctuation)), ("true", Theme.syntax(\.literal)),
            ("\n}", Theme.syntax(\.punctuation))
        ]
        return parts.reduce(into: AttributedString()) { result, part in
            var piece = AttributedString(part.0)
            piece.foregroundColor = part.1
            result += piece
        }
    }

    var body: some View {
        Text(sample)
            .font(.system(size: fontSize, design: .monospaced))
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            .accessibilityLabel("Code sample")
    }
}

/// A small PostWoman window in a theme's colors: title bar, sidebar, URL bar and JSON lines. Decorative.
private struct ThemeMiniWindow: View {
    let palette: ThemePalette
    let accent: AccentChoice

    private func color(_ hex: UInt32) -> Color { Color(nsColor: NSColor(hex: hex)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 3) {
                ForEach([0xFF5F57, 0xFEBC2E, 0x28C840] as [UInt32], id: \.self) { Circle().fill(color($0)).frame(width: 5, height: 5) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).frame(height: 14).background(color(palette.sidebar))
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    line(palette.muted, width: 18).opacity(0.5)
                    line(accent.hex(in: palette), width: 18)
                    line(palette.muted, width: 18).opacity(0.5)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 5).padding(.vertical, 6)
                .frame(width: 30)
                .frame(maxHeight: .infinity)
                .background(color(palette.sidebar))
                .overlay(alignment: .trailing) { Rectangle().fill(color(palette.border)).frame(width: 1) }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(verbatim: "GET").font(.system(size: 6, weight: .semibold, design: .monospaced)).foregroundStyle(color(palette.success))
                        line(palette.muted, width: nil).opacity(0.45)
                        RoundedRectangle(cornerRadius: 2).fill(color(accent.hex(in: palette))).frame(width: 14, height: 7)
                    }
                    .padding(.horizontal, 4).frame(height: 12)
                    .background(color(palette.field), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(color(palette.border)))
                    HStack(spacing: 3) {
                        line(palette.key, width: 20); line(palette.string, width: 30)
                    }
                    HStack(spacing: 3) {
                        line(palette.key, width: 15); line(palette.number, width: 12)
                    }.padding(.leading, 8)
                    HStack(spacing: 3) {
                        line(palette.key, width: 24); line(palette.literal, width: 18)
                    }.padding(.leading, 8)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(color(palette.background))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func line(_ hex: UInt32, width: CGFloat?) -> some View {
        if let width {
            Capsule().fill(color(hex)).frame(width: width, height: 3)
        } else {
            Capsule().fill(color(hex)).frame(height: 3).frame(maxWidth: .infinity)
        }
    }
}

/// The right part of a tile, cut on a slant: System's dark half.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.58, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.42, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
