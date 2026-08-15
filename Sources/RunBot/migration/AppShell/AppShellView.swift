import SwiftUI

struct AppShellView: View {
    var body: some View {
        NavigationSplitView {
            AppSidebarView()
                .navigationSplitViewColumnWidth(
                    min: 180,
                    ideal: 220,
                    max: 280
                )
        } detail: {
            AppDetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 720, minHeight: 480)
    }
}
