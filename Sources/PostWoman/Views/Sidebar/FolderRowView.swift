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

            if isHovered || isRenaming {
                Menu {
                    Button(action: { isRenaming = true }) {
                        Label("Rename Folder", systemImage: "pencil")
                    }
                    Button(action: exportFolder) {
                        Label("Export Collection...", systemImage: "square.and.arrow.up")
                    }
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

            Text("\(folder.requests?.count ?? 0)")
                .font(.subheadline)
                .foregroundColor(.secondary)
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
            Divider()
            Button(role: .destructive, action: deleteFolder) {
                Label("Delete Folder", systemImage: "trash")
            }
        }
    }

    private func deleteFolder() {
        modelContext.delete(folder)
    }

    private func exportFolder() {
        ExportImportService.exportFolderWithDialog(folder)
    }
}
