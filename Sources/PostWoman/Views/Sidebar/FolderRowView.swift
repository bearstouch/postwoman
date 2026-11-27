import SwiftUI
import SwiftData

struct FolderRowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var folder: Folder
    @State private var isRenaming: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder")
                .foregroundColor(.secondary)
                .accessibilityHidden(true)

            if isRenaming {
                TextField("Folder Name", text: $folder.name)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        isRenaming = false
                    }
            } else {
                Text(folder.name)
                    .lineLimit(1)
            }

            Spacer()

            if let environment = folder.selectedEnvironment {
                HStack(spacing: 4) {
                    Circle().fill(environment.color.swatch).frame(width: 6, height: 6)
                    Text(environment.name)
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(environment.color.swatch)
                .help("Requests in \(folder.name) use the \(environment.name) environment")
            }

            if isHovered || isRenaming {
                Menu {
                    Button(action: { isRenaming = true }) {
                        Label("Rename Folder", systemImage: "pencil")
                    }
                    Button(action: exportFolder) {
                        Label("Export Collection...", systemImage: "square.and.arrow.up")
                    }
                    environmentItems
                    Divider()
                    Button(role: .destructive, action: deleteFolder) {
                        Label("Delete Folder", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.system(size: 14))
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }

            Text("\(requestCount)")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .accessibilityLabel(requestCount == 1 ? "1 request" : "\(requestCount) requests")
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(action: { isRenaming = true }) {
                Label("Rename Folder", systemImage: "pencil")
            }
            Button(action: exportFolder) {
                Label("Export Collection...", systemImage: "square.and.arrow.up")
            }
            environmentItems
            Divider()
            Button(role: .destructive, action: deleteFolder) {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    private var requestCount: Int { folder.requests?.count ?? 0 }

    /// "Use Environment" and "Environments…" for this collection.
    @ViewBuilder
    private var environmentItems: some View {
        Divider()
        Picker(selection: Binding(get: { folder.selectedEnvironment?.id }, set: { folder.selectedEnvironmentID = $0 })) {
            Text("\(folder.defaultEnvironmentName) Only").tag(UUID?.none)
            ForEach(folder.overrideEnvironments, id: \.id) { environment in
                Text(environment.name).tag(Optional(environment.id))
            }
        } label: {
            Label("Use Environment", systemImage: "square.stack.3d.up")
        }
        Button {
            NotificationCenter.default.post(name: .manageEnvironments, object: nil, userInfo: ["folderID": folder.id])
        } label: {
            Label("Environments…", systemImage: "slider.horizontal.3")
        }
    }

    private func deleteFolder() {
        modelContext.delete(folder)
    }

    private func exportFolder() {
        ExportImportService.exportFolderWithDialog(folder)
    }
}
