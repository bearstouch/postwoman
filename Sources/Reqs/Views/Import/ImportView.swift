import AppKit
import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// What the Import sheet has read, and whether and where Import would store it. Files are read as soon as they are chosen,
/// dropped or pasted, so the sheet shows what each one is (and what won't come across) before anything is stored.
struct ImportPreview {
    /// A chosen file or the pasted text, read.
    struct Candidate: Identifiable {
        let id = UUID()
        let name: String
        let file: ImportedFile?
        /// Why it can't be imported.
        let problem: String?

        static func read(_ data: Data, name: String) -> Candidate {
            do {
                return Candidate(name: name, file: try CollectionImport.read(data, fileName: name), problem: nil)
            } catch {
                return Candidate(name: name, file: nil, problem: error.localizedDescription)
            }
        }

        /// "Postman collection · 5 requests, 2 environments".
        var detail: String { problem ?? file.map(ImportPreview.describe) ?? "" }
    }

    var candidates: [Candidate] = []

    var files: [ImportedFile] { candidates.compactMap(\.file) }

    /// "Postman collection · 5 requests", "Reqs collections file · 2 collections, 7 requests", "Postman environment · 3 variables".
    static func describe(_ file: ImportedFile) -> String {
        var parts: [String] = []
        if file.collections.count > 1 { parts.append(count(file.collections.count, "collection")) }
        if !file.collections.isEmpty { parts.append(count(file.collections.reduce(0) { $0 + $1.requests.count }, "request")) }
        let environments = file.collections.reduce(0) { $0 + ($1.environments ?? []).filter { !$0.isDefault }.count } + file.environments.count
        if environments > 0 || file.collections.isEmpty { parts.append(count(environments, "environment")) }
        if file.collections.isEmpty, file.environments.count == 1 { parts[parts.count - 1] = count(file.environments[0].variables.count, "variable") }
        return file.format.title + " · " + parts.joined(separator: ", ")
    }

    private static func count(_ number: Int, _ noun: String) -> String { "\(number) \(noun)\(number == 1 ? "" : "s")" }

    /// What can't be carried over, once each.
    var notes: [String] {
        var seen = Set<String>()
        return files.flatMap(\.notes).filter { seen.insert($0).inserted }
    }

    /// Where environment files go, or nil when there are none: the one collection imported with them, else `selectedName`.
    func environmentDestination(selectedName: String?) -> String? {
        guard files.contains(where: { !$0.environments.isEmpty }) else { return nil }
        let collections = files.flatMap(\.collections)
        if collections.count == 1 { return collections[0].name }
        return selectedName
    }

    /// Why Import is off; nil when it can run. Empty when nothing has been chosen yet (nothing to explain).
    func blocker(selectedName: String?) -> String? {
        if candidates.isEmpty { return "" }
        if candidates.contains(where: { $0.problem != nil }) { return "Remove the files that can't be imported, then try again." }
        if files.contains(where: { !$0.environments.isEmpty }) && environmentDestination(selectedName: selectedName) == nil {
            return CollectionImport.Failure.noCollectionForEnvironments.localizedDescription
        }
        return nil
    }
}

/// The Import sheet: choose or drop files (File), or paste an export (Text). It lists what each file is, what won't come
/// across and where environments go; Import stores them all, or nothing when it fails.
struct ImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    /// The collection selected in the sidebar, by ID and name (not the model, which an agent could delete while the sheet
    /// is open): environment files are added to it.
    let selectedCollectionID: PersistentIdentifier?
    let selectedCollectionName: String?

    init(selectedCollection: Folder?, onImport: @escaping (Folder?) -> Void = { _ in }) {
        selectedCollectionID = selectedCollection?.persistentModelID
        selectedCollectionName = selectedCollection?.name
        self.onImport = onImport
    }
    /// Called with the collection to select after importing.
    var onImport: (Folder?) -> Void = { _ in }

    enum Source: String, CaseIterable, Identifiable {
        case file = "File"
        case text = "Text"
        var id: String { rawValue }
    }

    @State private var source: Source = .file
    @State private var filePreview = ImportPreview()
    @State private var text = ""
    @State private var textPreview = ImportPreview()
    @State private var isTargeted = false
    @State private var failure: String?

    private var preview: ImportPreview { source == .file ? filePreview : textPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import").font(.title3.weight(.semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close")
            }

            Picker("Source", selection: $source) {
                ForEach(Source.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Import from")

            Group {
                switch source {
                case .file: fileArea
                case .text: textArea
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)

            details

            HStack(spacing: 4) {
                Text("Supported:").foregroundStyle(.secondary)
                Text(ImportFormat.supportedApps.joined(separator: ", ")).foregroundStyle(Color.appAccent)
            }
            .font(.callout)
            .accessibilityElement(children: .combine)
            .help("Reqs collection files, Postman collections (v2.0, v2.1) and environments, Hoppscotch collections and environments, Insomnia exports (v4 JSON, v5 YAML), OpenAPI 3 and Swagger 2.0 specs (JSON or YAML).")

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Import", action: importNow)
                    .keyboardShortcut(.defaultAction)
                    .disabled(preview.blocker(selectedName: selectedCollectionName) != nil)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .background(Theme.canvas)
        .task(id: text) {
            // Read pasted text once typing pauses, not on every keystroke.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            textPreview = trimmed.isEmpty ? ImportPreview() : ImportPreview(candidates: [.read(Data(trimmed.utf8), name: "Pasted text")])
        }
    }

    // MARK: - File

    private var fileArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(isTargeted ? Theme.selection : Theme.field)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isTargeted ? Color.appAccent : Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: isTargeted ? [6, 4] : []))
            if filePreview.candidates.isEmpty {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().fill(Theme.chip).frame(width: 64, height: 64)
                        Image(systemName: "paperclip").font(.system(size: 26)).foregroundStyle(.secondary)
                    }
                    .accessibilityHidden(true)
                    Text("Choose a file or drop it here").foregroundStyle(.secondary)
                    Button("Choose File…", action: chooseFiles)
                }
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(filePreview.candidates) { candidate in
                                ImportCandidateRow(candidate: candidate) { filePreview.candidates.removeAll { $0.id == candidate.id } }
                                HairlineDivider()
                            }
                        }
                    }
                    HStack {
                        Text("Drop more files here, or").foregroundStyle(.secondary)
                        Button("Add Files…", action: chooseFiles)
                        Spacer()
                    }
                    .font(.callout)
                    .padding(10)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return !urls.isEmpty
        } isTargeted: {
            isTargeted = $0
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Files to import")
    }

    // MARK: - Text

    private var textArea: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topLeading) {
                CodeTextEditor(text: $text, themeRevision: ThemeStore.shared.revision)
                    .accessibilityLabel("Pasted export")
                if text.isEmpty {
                    Text("Paste an exported collection, environment or OpenAPI spec (JSON or YAML)")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
            if let candidate = textPreview.candidates.first {
                ImportCandidateRow(candidate: candidate, onRemove: nil)
            }
        }
    }

    // MARK: - Details

    /// Where environments go, what won't come across, and why Import is off or failed.
    @ViewBuilder private var details: some View {
        let lines = detailLines
        if !lines.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Label {
                            Text(line.text).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: line.symbol).foregroundStyle(line.isProblem ? Theme.failure : Theme.neutral)
                        }
                        .font(.callout)
                        .foregroundStyle(line.isProblem ? AnyShapeStyle(Theme.failure) : AnyShapeStyle(.secondary))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 110)
        }
    }

    private var detailLines: [(text: String, symbol: String, isProblem: Bool)] {
        var lines: [(String, String, Bool)] = []
        if let failure { lines.append((failure, "exclamationmark.triangle.fill", true)) }
        if let destination = preview.environmentDestination(selectedName: selectedCollectionName) {
            lines.append(("Environments are added to “\(destination)”.", "square.stack.3d.up", false))
        }
        if let blocker = preview.blocker(selectedName: selectedCollectionName), !blocker.isEmpty, !preview.candidates.contains(where: { $0.problem != nil }) {
            lines.append((blocker, "exclamationmark.triangle.fill", true))
        }
        lines += preview.notes.map { ($0, "info.circle", false) }
        return lines
    }

    // MARK: - Actions

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json, .yaml]
        panel.allowsMultipleSelection = true
        panel.prompt = "Choose"
        panel.message = "Choose files exported from Reqs, Postman, Hoppscotch or Insomnia, or an OpenAPI or Swagger spec."
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        failure = nil
        for url in urls where !filePreview.candidates.contains(where: { $0.name == url.lastPathComponent && $0.file != nil }) {
            do {
                filePreview.candidates.append(.read(try Data(contentsOf: url), name: url.lastPathComponent))
            } catch {
                filePreview.candidates.append(ImportPreview.Candidate(name: url.lastPathComponent, file: nil, problem: error.localizedDescription))
            }
        }
    }

    private func importNow() {
        guard preview.blocker(selectedName: selectedCollectionName) == nil else { return }
        do {
            let outcome = try CollectionImport.commit(preview.files, context: modelContext, selectedID: selectedCollectionID)
            onImport(outcome.collections.first ?? outcome.environmentTarget)
            dismiss()
        } catch {
            failure = "Nothing was imported: \(error.localizedDescription)"
        }
    }
}

/// One chosen file: its name, what it is (or why it can't be imported, with a warning symbol, not color alone), and Remove.
struct ImportCandidateRow: View {
    let candidate: ImportPreview.Candidate
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: candidate.problem == nil ? "doc.text" : "exclamationmark.triangle.fill")
                    .foregroundStyle(candidate.problem == nil ? Theme.neutral : Theme.failure)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name).lineLimit(1).truncationMode(.middle)
                    Text(candidate.detail)
                        .font(.caption)
                        .foregroundStyle(candidate.problem == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.failure))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(candidate.problem == nil ? "Ready to import" : "Can't be imported")
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(candidate.name)")
                .accessibilityLabel("Remove \(candidate.name)")
            }
        }
        .padding(10)
    }
}
