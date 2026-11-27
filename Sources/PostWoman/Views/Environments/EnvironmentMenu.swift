import SwiftData
import SwiftUI

extension Notification.Name {
    /// Opens a collection's environments. `userInfo["folderID"]` (a `UUID`) names it; else the current collection.
    static let manageEnvironments = Notification.Name("PostWoman.manageEnvironments")

    /// Opens the New Environment sheet for the current collection (or `userInfo["folderID"]`).
    static let newEnvironment = Notification.Name("PostWoman.newEnvironment")

    /// Selects the current collection's environment at `userInfo["index"]`: 0 is Default only, 1… the others in order.
    static let selectEnvironment = Notification.Name("PostWoman.selectEnvironment")
}

/// The toolbar's environment picker for one collection: Default only or one of its other environments.
struct EnvironmentMenu: View {
    /// The collection of the request or folder being shown; nil disables the menu.
    let folder: Folder?

    var body: some View {
        Menu {
            if let folder {
                Picker("Environment", selection: selection(folder)) {
                    Text("\(folder.defaultEnvironmentName) only").tag(UUID?.none)
                    ForEach(folder.overrideEnvironments, id: \.id) { environment in
                        Text(environment.name).tag(Optional(environment.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("New Environment…") { post(.newEnvironment, folder) }
                Button("Manage Environments…") { post(.manageEnvironments, folder) }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .foregroundStyle(folder?.selectedEnvironment?.color.swatch ?? Theme.info)
                    .font(.system(size: 8))
                Text(folder?.activeEnvironmentName ?? "No Environment")
            }
        }
        .disabled(folder == nil)
        .help(
            folder.map { "Environment for \($0.name)'s requests. \($0.defaultEnvironmentName) always applies; the one you pick overrides it." }
                ?? "Requests outside a collection have no environment.")
    }

    private func selection(_ folder: Folder) -> Binding<UUID?> {
        Binding(get: { folder.selectedEnvironment?.id }, set: { folder.selectedEnvironmentID = $0 })
    }

    private func post(_ name: Notification.Name, _ folder: Folder) {
        NotificationCenter.default.post(name: name, object: nil, userInfo: ["folderID": folder.id])
    }
}

/// Makes a new environment in a collection: empty (everything from Default) or a copy of another one.
struct NewEnvironmentView: View {
    @Environment(\.dismiss) private var dismiss
    let folder: Folder
    /// Called with the new environment, so the caller can show it.
    var onCreate: (CollectionEnvironment) -> Void = { _ in }

    @State private var name = ""
    @State private var color: EnvironmentColor = .green
    @State private var copyFrom: UUID?
    @State private var startsAsCopy = false
    @State private var selectsNow = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Environment").font(.headline)
                Label(folder.name, systemImage: "folder").font(.caption).foregroundStyle(.secondary)
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("Staging", text: $name)
                        .textFieldStyle(.themed)
                        .onSubmit(create)
                }
                GridRow(alignment: .top) {
                    Text("Start with").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Start with", selection: $startsAsCopy) {
                            Text("No overrides: everything comes from \(folder.defaultEnvironmentName)").tag(false)
                            Text("A copy of another environment").tag(true)
                        }
                        .pickerStyle(.radioGroup)
                        .labelsHidden()
                        if startsAsCopy {
                            Picker("Copy of", selection: $copyFrom) {
                                ForEach(copySources, id: \.id) { environment in
                                    Text(environment.name).tag(Optional(environment.id))
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            .padding(.leading, 20)
                        }
                    }
                }
                GridRow {
                    Text("Color").foregroundStyle(.secondary)
                    Picker("Color", selection: $color) {
                        ForEach(EnvironmentColor.allCases) { color in
                            Label {
                                Text(color.title)
                            } icon: {
                                Image(systemName: "circle.fill").foregroundStyle(color.swatch)
                            }.tag(color)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Toggle("Use it for \(folder.name) now", isOn: $selectsNow)

            Text("This environment belongs to \(folder.name) only. It is exported with the collection, with secret values left empty.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: create)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.canvas)
        .onAppear {
            copyFrom = folder.selectedEnvironment?.id ?? copySources.first?.id
            color = EnvironmentActions.colorForNew(in: folder)
        }
    }

    private var copySources: [CollectionEnvironment] { EnvironmentActions.copySources(in: folder) }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func create() {
        guard
            let environment = EnvironmentActions.create(
                named: name, color: color, copyFrom: startsAsCopy ? copyFrom : nil, in: folder, selectsNow: selectsNow)
        else { return }
        onCreate(environment)
        dismiss()
    }
}
