import AppKit
import SwiftUI

/// The Preview tab: the request as it will go on the wire, with the collection's environment filled in, secrets
/// masked. It reads the request each time it draws, so it follows every edit.
struct RequestPreviewView: View {
    let request: APIRequest
    let resolver: VariableResolver?

    var body: some View {
        let outcome = RequestPreview.make(request, resolver: resolver ?? .empty)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if case .request(let text) = outcome {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy the request as shown")
                    .accessibilityLabel("Copy Request")
                }
            }
            .padding()
            .background(Theme.bar)

            HairlineDivider()

            switch outcome {
            case .request(let text):
                ResponseTextView(
                    text: text, highlightsJSON: request.bodyType == .json, wrapsLines: true, highlightsHTTP: true, font: ThemeStore.shared.codeFont,
                    themeRevision: ThemeStore.shared.revision
                )
                .background(Theme.field)
                .accessibilityLabel("Request preview")
            case .invalidURL:
                Text(RequestPreview.invalidURLMessage)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HairlineDivider()
            Text(RequestPreview.footnote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(RequestPreview.footnoteDetail)
                .padding(.horizontal)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.bar)
        }
    }
}
