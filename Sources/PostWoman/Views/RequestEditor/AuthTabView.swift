import SwiftUI

struct AuthTabView: View {
    @Bindable var request: APIRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Authentication")
                        .font(.headline)
                    Spacer()
                    Picker("Type", selection: $request.authenticationType) {
                        ForEach(AuthenticationType.allCases) { type in
                            Text(type.rawValue).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                Divider()

                switch request.authenticationType {
                case .none:
                    noAuthView
                case .bearer:
                    bearerAuthView
                case .basic:
                    basicAuthView
                case .oauth2:
                    oauth2View
                }

                Spacer()
            }
            .padding()
        }
    }

    private var noAuthView: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.open")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text("No Authentication")
                .font(.title3)
            Text("This request does not require authentication.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private var bearerAuthView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bearer Token")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack {
                SecureField(
                    "Enter token",
                    text: Binding(
                        get: { request.authBearerToken ?? "" },
                        set: { request.authBearerToken = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Button(action: {
                    if let token = request.authBearerToken {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(token, forType: .string)
                    }
                }) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("Copy to clipboard")
            }

            Text("The token will be sent as: Authorization: Bearer <token>")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var basicAuthView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Basic Authentication")
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("Username")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(
                        "Username",
                        text: Binding(
                            get: { request.authBasicUsername ?? "" },
                            set: { request.authBasicUsername = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading) {
                    Text("Password")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    SecureField(
                        "Password",
                        text: Binding(
                            get: { request.authBasicPassword ?? "" },
                            set: { request.authBasicPassword = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                }
            }

            Text("Credentials will be Base64 encoded and sent as: Authorization: Basic <encoded>")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var oauth2View: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OAuth 2.0 Configuration")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Group {
                LabeledTextField(
                    label: "Authorization URL",
                    text: Binding(
                        get: { request.authOAuthConfig?.authorizationURL ?? "" },
                        set: { updateOAuthConfig { $0.authorizationURL = $1 }($0) }
                    ))

                LabeledTextField(
                    label: "Token URL",
                    text: Binding(
                        get: { request.authOAuthConfig?.tokenURL ?? "" },
                        set: { updateOAuthConfig { $0.tokenURL = $1 }($0) }
                    ))

                LabeledTextField(
                    label: "Client ID",
                    text: Binding(
                        get: { request.authOAuthConfig?.clientID ?? "" },
                        set: { updateOAuthConfig { $0.clientID = $1 }($0) }
                    ))

                LabeledTextField(
                    label: "Client Secret",
                    text: Binding(
                        get: { request.authOAuthConfig?.clientSecret ?? "" },
                        set: { updateOAuthConfig { $0.clientSecret = $1 }($0) }
                    ), isSecure: true)

                LabeledTextField(
                    label: "Scope",
                    text: Binding(
                        get: { request.authOAuthConfig?.scope ?? "" },
                        set: { updateOAuthConfig { $0.scope = $1 }($0) }
                    ))

                LabeledTextField(
                    label: "Redirect URI",
                    text: Binding(
                        get: { request.authOAuthConfig?.redirectURI ?? "" },
                        set: { updateOAuthConfig { $0.redirectURI = $1 }($0) }
                    ))
            }

            Button("Get New Access Token") {
                // OAuth flow would be triggered here
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
    }

    private func updateOAuthConfig(_ update: @escaping (inout OAuthConfig, String) -> Void) -> (String) -> Void {
        return { newValue in
            var config = request.authOAuthConfig ?? OAuthConfig()
            update(&config, newValue)
            request.authOAuthConfig = config
        }
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    var isSecure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            if isSecure {
                SecureField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField(label, text: $text)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
