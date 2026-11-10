import SwiftUI

/// The application menu always has an exit from its nested pages. Keep this
/// shell mounted while its contents change, and reset only at menu visibility.
struct NBAMainMenuNavigation<Content: View>: View {
    @Binding var showingDetail: Bool
    @Binding var showingHistory: Bool
    var showSettings: () -> Void
    @ViewBuilder var content: () -> Content

    private func home() { showingDetail = false; showingHistory = false }

    var body: some View {
        VStack(spacing: 0) {
            if showingDetail || showingHistory {
                HStack {
                    Button(action: home) { Label("主菜单", systemImage: "chevron.left") }
                        .accessibilityIdentifier("main-menu-home")
                    Spacer()
                    Button { home(); showSettings() } label: { Label("设置", systemImage: "gearshape") }
                        .accessibilityIdentifier("main-menu-settings")
                }.buttonStyle(.plain).foregroundStyle(.blue).font(.system(size: 12))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                Divider()
            }
            content()
        }
        .onAppear(perform: home)
        .onDisappear(perform: home)
    }
}
