import SwiftUI

/// 设置窗口根视图（FR-11 / FR-12 / FR-13 / FR-14 / FR-15 / FR-16）：
/// 全局设置按功能域拆为「全局 / 屏保 / 壁纸」三页，各控件行尾「?」帮助按钮收纳说明文案
/// （悬停显示 tooltip，点击弹出气泡）；素材管理集成于显示器壁纸设置的分栏中。
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("全局设置", systemImage: "gearshape") }
            ScreenSaverSettingsView()
                .tabItem { Label("屏保设置", systemImage: "sparkles.tv") }
            WallpaperSettingsView()
                .tabItem { Label("壁纸设置", systemImage: "photo.on.rectangle.angled") }
            DisplaySettingsView()
                .tabItem { Label("显示器", systemImage: "display") }
            MediaAppsView()
                .tabItem { Label("媒体应用", systemImage: "music.note.list") }
        }
        .frame(minWidth: 760, minHeight: 480)
        .padding(.top, 20)
    }
}