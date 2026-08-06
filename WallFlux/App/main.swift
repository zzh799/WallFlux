import AppKit

// 程序入口：显式创建 NSApplication 并设置 delegate。
// 注意：不使用 @main（NSApplicationMain 仅从 main storyboard 实例化 delegate，
// 无 storyboard 时 delegate 永远不会被创建，applicationDidFinishLaunching 不会触发）。
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
