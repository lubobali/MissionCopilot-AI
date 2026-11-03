import SwiftUI

extension View {
    /// A whole screen: the theme background edge to edge, text in the theme text color, actions in the
    /// accent (#87). It takes all the room first, so the background is not only behind the content.
    func fieldScreen() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.background).ignoresSafeArea())
            .foregroundStyle(Color(.text))
            .tint(Color(.accent))
    }

    /// A list screen: the list's own gray background hidden so the theme background shows.
    func fieldList() -> some View {
        scrollContentBackground(.hidden).fieldScreen()
    }
}
