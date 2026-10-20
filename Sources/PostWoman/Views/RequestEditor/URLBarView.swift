import SwiftUI

struct URLBarView: View {
    @Binding var url: String
    @Binding var method: HTTPMethod
    let isLoading: Bool
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Method", selection: $method) {
                ForEach(HTTPMethod.allCases) { method in
                    Text(method.rawValue)
                        .tag(method)
                }
            }
            .labelsHidden()
            .frame(width: 100)
            .tint(method.color)

            TextField("Enter request URL", text: $url)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .onSubmit(onSend)

            Button(action: onSend) {
                if isLoading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 50)
                } else {
                    Text("Send")
                        .frame(width: 50)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(url.isEmpty || isLoading)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }
}

#Preview {
    @Previewable @State var url = "https://api.example.com/users"
    @Previewable @State var method: HTTPMethod = .get

    URLBarView(
        url: $url,
        method: $method,
        isLoading: false,
        onSend: {}
    )
    .padding()
}
