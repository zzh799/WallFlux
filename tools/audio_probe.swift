// 媒体播放诊断工具（临时，复现「抖音暂停仍阻止屏保播放」用）
//
// 输出三组对照数据，用于确认根因：
//   1. CoreAudio 出声进程（kAudioProcessPropertyIsRunningOutput，与 MediaPlaybackMonitor 同源）
//   2. 各出声进程持有的 IOKit 防睡眠断言（IOPMCopyAssertionsByProcess，公开 API）
//      - PreventUserIdleDisplaySleep / PreventUserIdleSystemSleep：视频/音频播放时的典型断言，
//        暂停后通常释放 —— 若成立，可作为「真的在播」的判别信号
//   3. 各出声进程的 layer0 普通窗口数（0 个窗口 → MediaPlaybackMonitor 会回退命中所有显示器）
//
// 用法：
//   swift tools/audio_probe.swift            # 单次快照
//   swift tools/audio_probe.swift --watch 3  # 每 3 秒输出一次（Ctrl-C 退出）
import AppKit
import CoreAudio
import CoreGraphics
import Darwin
import Foundation
import IOKit.pwr_mgt

let watchInterval: Double = {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--watch"), i + 1 < args.count,
          let v = Double(args[i + 1]) else { return 0 }
    return v
}()

/// 进程显示名：优先 NSRunningApplication 本地化名称，否则回退 PID
func displayName(pid: Int32) -> String {
    if let app = NSRunningApplication(processIdentifier: pid),
       let name = app.localizedName, !name.isEmpty {
        return name
    }
    return "PID \(pid)"
}

/// 读取音频进程对象的数值属性
func audioProcessProperty<T>(_ objectID: AudioObjectID,
                             _ selector: AudioObjectPropertySelector) -> T? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let valuePtr = UnsafeMutablePointer<T>.allocate(capacity: 1)
    defer { valuePtr.deallocate() }
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, valuePtr)
    guard status == noErr else { return nil }
    return valuePtr.pointee
}

/// 读取音频进程对象的 CFString 属性（AudioObjectGetPropertyData 返回 +1 引用）
func audioProcessCFStringProperty(_ objectID: AudioObjectID,
                                  _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, $0)
    }
    guard status == noErr, let unmanaged = value else { return nil }
    let string = unmanaged.takeRetainedValue() as String
    return string.isEmpty ? nil : string
}

/// 全部音频客户端进程中「正在输出声音」的进程
func outputAudioProcesses() -> [(pid: Int32, bundleID: String?, name: String)] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr, size > 0 else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var processIDs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &processIDs) == noErr else {
        return []
    }

    let ownPID = ProcessInfo.processInfo.processIdentifier
    var result: [(pid: Int32, bundleID: String?, name: String)] = []
    for objectID in processIDs {
        guard let pid: Int32 = audioProcessProperty(objectID, kAudioProcessPropertyPID),
              pid > 0, pid != ownPID else { continue }
        let isRunningOutput: UInt32 = audioProcessProperty(objectID, kAudioProcessPropertyIsRunningOutput) ?? 0
        guard isRunningOutput != 0 else { continue }
        let bundleID = audioProcessCFStringProperty(objectID, kAudioProcessPropertyBundleID)
        result.append((pid, bundleID, displayName(pid: pid)))
    }
    return result
}

/// 全系统断言持有者：PID → [断言类型]，仅统计与播放相关的类型
/// IOPMCopyAssertionsByProcess 返回 PID → 断言字典数组（字典内含 "AssertionType" 键）
func playbackAssertions() -> [Int32: [String]] {
    var dict: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
          let unmanaged = dict else { return [:] }
    let nsDict = unmanaged.takeRetainedValue() as NSDictionary
    var result: [Int32: [String]] = [:]
    let relevant = ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep"]
    for (pidNum, value) in nsDict {
        guard let pidNum = pidNum as? NSNumber else { continue }
        var types: [String] = []
        if let arr = value as? [Any] {
            for item in arr {
                if let s = item as? String {
                    types.append(s)
                } else if let d = item as? [String: Any],
                          let type = (d["AssertType"] as? String) ?? (d["AssertionTrueType"] as? String) {
                    types.append(type)
                }
            }
        } else if let s = value as? String {
            types.append(s)
        }
        let filtered = types.filter { relevant.contains($0) }
        if !filtered.isEmpty {
            result[pidNum.int32Value] = filtered
        }
    }
    return result
}

/// 进程 layer0 普通窗口数（与 MediaPlaybackMonitor.displayIDs(for:) 的判定口径一致）
func layer0WindowCount(pid: Int32) -> Int {
    guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
        return -1 // 查询失败
    }
    return windows.filter { win in
        guard let owner = win[kCGWindowOwnerPID as String] as? Int, owner == Int(pid) else { return false }
        guard let layer = win[kCGWindowLayer as String] as? Int, layer == 0 else { return false }
        guard let alpha = win[kCGWindowAlpha as String] as? Double, alpha > 0 else { return false }
        guard let bounds = win[kCGWindowBounds as String] as? [String: CGFloat],
              bounds["Width"] ?? 0 > 50, bounds["Height"] ?? 0 > 50 else { return false }
        return true
    }.count
}

func snapshot(round: Int) {
    let date = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    print("\n========== 快照 #\(round) @ \(formatter.string(from: date)) ==========")
    let procs = outputAudioProcesses()
    if procs.isEmpty {
        print("当前无进程正在输出声音（IsRunningOutput 全为 0）")
        fflush(stdout)
        return
    }
    let assertions = playbackAssertions()
    var anyWindowless = false
    print("PID        名称                        BundleID                                  layer0窗口  播放断言")
    for proc in procs {
        let pid = proc.pid
        let wins = layer0WindowCount(pid: pid)
        if wins == 0 { anyWindowless = true }
        let assertText = assertions[pid]?.joined(separator: ",") ?? "-"
        print("\(pid)  \(proc.name)  \(proc.bundleID ?? "nil")  \(wins)  \(assertText)")
    }
    print("—— 任一出声进程无窗口 → MediaPlaybackMonitor 将回退命中所有显示器：\(anyWindowless ? "是（⚠️ 拖累所有屏）" : "否")")
    print("—— 出声进程是否持有 PreventUserIdleDisplaySleep/SystemSleep：\(procs.contains { assertions[$0.pid] != nil } ? "是" : "否")")
    fflush(stdout) // 重定向到文件时保持逐行实时落盘
}

// 主流程：单次或按 --watch 间隔循环
setbuf(stdout, nil) // stdout 无缓冲，保证实时落盘
snapshot(round: 1)
if watchInterval > 0 {
    var round = 1
    while true {
        Thread.sleep(forTimeInterval: watchInterval)
        round += 1
        snapshot(round: round)
    }
}
