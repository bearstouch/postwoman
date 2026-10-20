import SwiftUI

struct RequestRowView: View {
    let request: APIRequest

    var body: some View {
        HStack(spacing: 8) {
            Text(request.method.rawValue)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(request.method.color)
                .frame(width: 45, alignment: .leading)

            Text(request.name)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()
        }
        .padding(.leading, 4)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 8) {
        RequestRowView(
            request: {
                let r = APIRequest(name: "Get Users", url: "https://api.example.com/users")
                r.method = .get
                return r
            }())
        RequestRowView(
            request: {
                let r = APIRequest(name: "Create User", url: "https://api.example.com/users")
                r.method = .post
                return r
            }())
        RequestRowView(
            request: {
                let r = APIRequest(name: "Update User", url: "https://api.example.com/users/1")
                r.method = .put
                return r
            }())
        RequestRowView(
            request: {
                let r = APIRequest(name: "Delete User", url: "https://api.example.com/users/1")
                r.method = .delete
                return r
            }())
    }
    .padding()
    .frame(width: 250)
}
