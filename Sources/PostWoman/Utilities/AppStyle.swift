import SwiftUI

extension Color {
    /// PostWoman's pink accent. SwiftPM builds have no asset catalog, so it is applied with `.tint`
    /// at each scene root and used directly where views previously read `Color.accentColor`.
    static let postWomanPink = Color(.sRGB, red: 1.0, green: 0.380, blue: 0.984)
}
