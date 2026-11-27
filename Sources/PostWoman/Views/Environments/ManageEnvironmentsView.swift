import SwiftData
import SwiftUI

/// One collection's environments: Default, which always applies, and the ones that override it.
struct ManageEnvironmentsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Bindable var folder: Folder

    /// The environment being edited.
    @State private var editingID: UUID?

    init(folder: Folder, editing environmentID: UUID? = nil) {
        self.folder = folder
        _editingID = State(initialValue: environmentID)
    }

    private var editing: CollectionEnvironment? {
        (folder.environments ?? []).first { $0.id == editingID } ?? folder.defaultEnvironment
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("\(folder.name) · Environments", systemImage: "square.stack.3d.up")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Theme.bar)

            HairlineDivider()

            HStack(spacing: 0) {
                environmentList
                    .frame(width: 230)
                    .background(Theme.listBackground)
                Rectangle().fill(Theme.hairline).frame(width: 1)
                if let editing {
                    EnvironmentEditorView(environment: editing, folder: folder)
                        .id(editing.id)
                } else {
                    Spacer()
                }
            }

            HairlineDivider()

            HStack {
                Text("Write {{name}} in a request's URL, params, headers, body or auth.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(Theme.bar)
        }
        .frame(width: 900, height: 580)
        .background(Theme.canvas)
        .onAppear {
            folder.ensureDefaultEnvironment()
            if editingID == nil { editingID = folder.selectedEnvironment?.id ?? folder.defaultEnvironment?.id }
        }
    }

    private var environmentList: some View {
        VStack(spacing: 0) {
            // Plain rows rather than List(selection:), whose clicks a sheet doesn't always deliver.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let defaultEnvironment = folder.defaultEnvironment {
                        row(for: defaultEnvironment, isSelected: folder.selectedEnvironment == nil)
                    }
                    Text("Overrides")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 12)
                        .padding(.bottom, 2)
                    ForEach(folder.overrideEnvironments, id: \.id) { environment in
                        row(for: environment, isSelected: folder.selectedEnvironmentID == environment.id)
                            .contextMenu {
                                Button("Use for Requests") { folder.selectedEnvironment = environment }
                                Button("Duplicate") { duplicate(environment) }
                                Divider()
                                Button("Delete", role: .destructive) { delete(environment) }
                            }
                    }
                }
                .padding(8)
            }

            HairlineDivider()

            HStack(spacing: 4) {
                Button(action: add) { Image(systemName: "plus").frame(width: 20, height: 18) }
                    .help("New Environment")
                Button(action: { if let editing, !editing.isDefault { delete(editing) } }) {
                    Image(systemName: "minus").frame(width: 20, height: 18)
                }
                .help("Delete Environment")
                .disabled(editing?.isDefault ?? true)
                Spacer()
                Button("Duplicate") { if let editing { duplicate(editing) } }
                    .disabled(editing == nil)
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
    }

    /// An environment in the list; clicking it opens it in the editor.
    private func row(for environment: CollectionEnvironment, isSelected: Bool) -> some View {
        let isEditing = editing?.id == environment.id
        return Button {
            editingID = environment.id
        } label: {
            EnvironmentListRow(environment: environment, isSelected: isSelected)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isEditing ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isEditing ? .isSelected : [])
    }

    private func add() {
        let used = Set(EnvironmentColor.allCases.prefix(3)).subtracting(folder.overrideEnvironments.map(\.color))
        let environment = folder.addEnvironment(
            named: uniqueName("New Environment"), color: used.sorted { $0.rawValue < $1.rawValue }.first ?? .gray)
        editingID = environment.id
    }

    private func duplicate(_ environment: CollectionEnvironment) {
        let copies = environment.variables.map { Variable(key: $0.key, value: $0.value, isEnabled: $0.isEnabled, isSecret: $0.isSecret) }
        let name = environment.isDefault ? "New Environment" : "\(environment.name) Copy"
        let copy = folder.addEnvironment(named: uniqueName(name), color: environment.isDefault ? .gray : environment.color, variables: copies)
        editingID = copy.id
    }

    private func delete(_ environment: CollectionEnvironment) {
        guard !environment.isDefault else { return }
        if folder.selectedEnvironmentID == environment.id { folder.selectedEnvironmentID = nil }
        if editingID == environment.id { editingID = folder.defaultEnvironment?.id }
        modelContext.delete(environment)
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set((folder.environments ?? []).map(\.name))
        guard names.contains(base) else { return base }
        var index = 2
        while names.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}

/// An environment in the list: its color, name, a badge when requests use it, and its variable count.
private struct EnvironmentListRow: View {
    let environment: CollectionEnvironment
    /// Requests resolve with it (for Default: no other environment is selected).
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            if environment.isDefault {
                Circle().strokeBorder(environment.color.swatch, lineWidth: 1.5).frame(width: 9, height: 9)
            } else {
                Circle().fill(environment.color.swatch).frame(width: 9, height: 9)
            }
            Text(environment.name)
                .fontWeight(environment.isDefault ? .semibold : .regular)
                .lineLimit(1)
            if isSelected, !environment.isDefault {
                Text("IN USE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(Theme.canvas)
            }
            Spacer()
            Text("\(environment.variables.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(environment.isDefault ? "\(environment.name) always applies. Other environments override it." : environment.name)
    }
}

/// The editor for one environment: name, color, and its variables.
private struct EnvironmentEditorView: View {
    @Bindable var environment: CollectionEnvironment
    @Bindable var folder: Folder

    /// Default's variables, by name, for the values an override replaces or inherits.
    private var defaults: [Variable] { environment.isDefault ? [] : (folder.defaultEnvironment?.variables ?? []) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(spacing: 0) {
                    columnTitles
                    HairlineDivider()
                    ForEach($environment.variables) { $variable in
                        VariableRowView(
                            variable: $variable,
                            defaultValue: environment.isDefault ? nil : .some(defaultVariable(named: variable.key)),
                            defaultName: folder.defaultEnvironmentName,
                            onDelete: { environment.variables.removeAll { $0.id == variable.id } })
                        HairlineDivider()
                    }
                    ForEach(inherited) { variable in
                        InheritedVariableRow(variable: variable) {
                            environment.variables.append(Variable(key: variable.key, value: variable.isSecret ? "" : variable.value, isSecret: variable.isSecret))
                        }
                        HairlineDivider()
                    }
                    HStack {
                        Button {
                            environment.variables.append(Variable())
                        } label: {
                            Label("Add Variable", systemImage: "plus")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Spacer()
                    }
                    .padding(10)
                }
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))

                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .onChange(of: environment.variables) { _, _ in environment.updatedAt = Date() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            TextField("Name", text: $environment.name)
                .textFieldStyle(.themed)
                .frame(width: 220)
                .help(environment.isDefault ? "Rename this collection's default environment. It always applies, whatever it is called." : "")
            if !environment.isDefault {
                HStack(spacing: 6) {
                    ForEach(EnvironmentColor.allCases) { color in
                        Button {
                            environment.color = color
                        } label: {
                            Circle()
                                .fill(color.swatch)
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Theme.canvas, lineWidth: environment.color == color ? 2 : 0).padding(2))
                                .overlay(Circle().strokeBorder(environment.color == color ? Color.primary : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(.plain)
                        .help(color.title)
                        .accessibilityLabel(color.title)
                        .accessibilityAddTraits(environment.color == color ? .isSelected : [])
                    }
                }
            }
            Spacer()
            if environment.isDefault {
                Text("Always applies")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if folder.selectedEnvironmentID == environment.id {
                Button("Stop Using") { folder.selectedEnvironmentID = nil }
                    .help("Requests in \(folder.name) go back to \(folder.defaultEnvironmentName) only.")
            } else {
                Button("Use for Requests") { folder.selectedEnvironment = environment }
            }
        }
    }

    private var columnTitles: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: 18, height: 1)
            Text("VARIABLE").frame(width: 160, alignment: .leading)
            Text(environment.isDefault ? "VALUE" : "VALUE IN \(environment.name.uppercased())").frame(maxWidth: .infinity, alignment: .leading)
            if !environment.isDefault { Text("\(folder.defaultEnvironmentName.uppercased()) VALUE").lineLimit(1).frame(width: 150, alignment: .leading) }
            Text("SECRET").frame(width: 50)
            Color.clear.frame(width: 18, height: 1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    /// Default's variables this environment doesn't set: requests still get them from Default.
    private var inherited: [Variable] {
        let overridden = Set(environment.variables.map { $0.key.trimmingCharacters(in: .whitespaces) })
        return defaults.filter { $0.isEnabled && !$0.key.isEmpty && !overridden.contains($0.key.trimmingCharacters(in: .whitespaces)) }
    }

    private func defaultVariable(named key: String) -> Variable? {
        let key = key.trimmingCharacters(in: .whitespaces)
        return defaults.first { $0.isEnabled && $0.key.trimmingCharacters(in: .whitespaces) == key && !key.isEmpty }
    }

    private var explanation: String {
        if environment.isDefault {
            return
                "\(environment.name) is this collection's default environment: it applies to every request in \(folder.name), so requests work with no other environment in use. Other environments override it only where they set a value. Secret values are masked here and in generated code, kept out of History and exports, and agents can set them but not read them."
        }
        return
            "\(environment.name) overrides \(folder.defaultEnvironmentName) only for the variables it sets. Rows marked ↳ come from \(folder.defaultEnvironmentName); choose Override to give them another value here."
    }
}

/// One variable: enabled, name, value (masked when secret), Default's value (for an override) and the secret switch.
private struct VariableRowView: View {
    @Binding var variable: Variable
    /// nil: this is Default. `.some(nil)`: an override that Default doesn't define.
    let defaultValue: Variable??
    /// What the collection calls its Default environment.
    var defaultName = CollectionEnvironment.defaultName
    let onDelete: () -> Void
    @State private var reveals = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $variable.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 18)
            TextField("name", text: $variable.key)
                .textFieldStyle(.themed)
                .font(.system(.body, design: .monospaced))
                .frame(width: 160)
            HStack(spacing: 4) {
                if variable.isSecret, !reveals {
                    SecureField("value", text: $variable.value)
                        .textFieldStyle(.themed)
                } else {
                    TextField("value", text: $variable.value)
                        .textFieldStyle(.themed)
                        .font(.system(.body, design: .monospaced))
                }
                if variable.isSecret {
                    Button {
                        reveals.toggle()
                    } label: {
                        Image(systemName: reveals ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .help(reveals ? "Hide Value" : "Show Value")
                }
            }
            .frame(maxWidth: .infinity)
            if let defaultValue {
                Group {
                    if let replaced = defaultValue {
                        Text(replaced.isSecret ? VariableDescription.mask : replaced.value)
                            .strikethrough()
                    } else {
                        Text("not in \(defaultName)").italic()
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            }
            Toggle(isOn: $variable.isSecret) { Image(systemName: variable.isSecret ? "lock.fill" : "lock.open") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .foregroundStyle(variable.isSecret ? Theme.accent : .secondary)
                .help(variable.isSecret ? "Secret: masked, kept out of History and exports" : "Make Secret")
                .frame(width: 50)
            Button(action: onDelete) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help("Remove Variable")
                .frame(width: 18)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(variable.isEnabled ? 1 : 0.5)
    }
}

/// A Default variable an override doesn't set, shown so it is clear requests still get it.
private struct InheritedVariableRow: View {
    let variable: Variable
    let onOverride: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("↳").frame(width: 18).foregroundStyle(Theme.info)
            Text(variable.key)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Theme.info)
                .frame(width: 160, alignment: .leading)
            HStack(spacing: 4) {
                Text("Inherited ·").foregroundStyle(.secondary)
                Button("Override", action: onOverride)
                    .buttonStyle(.link)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(variable.isSecret ? VariableDescription.mask : variable.value)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.info)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            Color.clear.frame(width: 50, height: 1)
            Color.clear.frame(width: 18, height: 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
