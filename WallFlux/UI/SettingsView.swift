import SwiftUI

/// 设置窗口根视图（FR-11 / FR-12 / FR-13：素材管理集成于显示器壁纸设置的分栏中）
struct SettingsView: View {
    var body: some View {
        TabView {
            GlobalSettingsView()
                .tabItem { Label("全局设置", systemImage: "gearshape") }
            DisplaySettingsView()
                .tabItem { Label("显示器", systemImage: "display") }
        }
        .frame(minWidth: 760, minHeight: 480)
        .padding(.top, 20)
    }
}
