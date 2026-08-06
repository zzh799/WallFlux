import SwiftUI

/// 设置窗口根视图（FR-11 / FR-12 / FR-13）
struct SettingsView: View {
    var body: some View {
        TabView {
            GlobalSettingsView()
                .tabItem { Label("全局设置", systemImage: "gearshape") }
            DisplaySettingsView()
                .tabItem { Label("显示器", systemImage: "display") }
            AssetManagementView()
                .tabItem { Label("素材管理", systemImage: "photo.on.rectangle.angled") }
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}
