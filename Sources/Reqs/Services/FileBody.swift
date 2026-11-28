import Foundation
import UniformTypeIdentifiers

/// A File body: the bytes of a file the user chose, sent as the whole request body. The request keeps its own copy (so it
/// can be sent after the original moves); History and exports keep only the file's name.
enum FileBody {
    /// The largest file a request takes: its bytes are held in memory to send.
    static let maximumSize = 25 * 1024 * 1024

    enum Failure: LocalizedError, Equatable {
        case tooLarge(String, Int)
        case unreadable(String)
        case notAFile(String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name, let size):
                "“\(name)” is \(FileBody.formattedSize(size)). A File body can be at most \(FileBody.formattedSize(FileBody.maximumSize))."
            case .unreadable(let name): "“\(name)” couldn't be read."
            case .notAFile(let name): "“\(name)” is a folder. Choose a file."
            }
        }
    }

    /// The name and bytes of the file at `url`. A URL from an open panel is security-scoped in the sandbox, so access is
    /// started around the read; the size is checked before reading, so a huge file is refused without loading it.
    static func read(_ url: URL) throws(Failure) -> (name: String, data: Data) {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values?.isDirectory == true { throw .notAFile(name) }
        if let size = values?.fileSize, size > maximumSize { throw .tooLarge(name, size) }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable(name) }
        guard data.count <= maximumSize else { throw .tooLarge(name, data.count) }
        return (name, data)
    }

    /// The Content-Type a file is sent with unless the request names one: its extension's MIME type, else
    /// `application/octet-stream` (bytes of no particular type).
    static func mimeType(forFileName name: String?) -> String {
        let fileExtension = ((name ?? "") as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension), let mime = type.preferredMIMEType else { return "application/octet-stream" }
        return mime
    }

    /// The path generated code reads the file from: its name in the current directory. Only the last path component
    /// (a name an agent set could hold `/`), `./` before a leading `-` (curl reads `@-` as standard input), `file` for no name.
    static func codePath(forFileName name: String?) -> String {
        let last = ((name ?? "") as NSString).lastPathComponent
        if last.isEmpty || last == "/" || last == "." || last == ".." { return "file" }
        return last.hasPrefix("-") ? "./" + last : last
    }

    /// A byte count as Finder writes it ("12 KB", "3.4 MB").
    static func formattedSize(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    /// Why a File request without bytes can't be sent: no file was chosen, or only its name is left (a request restored
    /// from History or imported, which keep no file bytes).
    static func missingFileMessage(fileName: String?) -> String {
        guard let fileName, !fileName.isEmpty else { return "No file to send. Choose one in the Body tab, or pick another body type." }
        return "“\(fileName)” isn't attached: Reqs has only its name (History and imports keep no file). Choose the file again in the Body tab."
    }
}
