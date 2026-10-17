//
//  AccessibilityMenuBarBackend.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import AXSwift6

/// macOS 27 的状态项目由宿主合成，不能再用 CGWindowID 表示单个项目。
/// 此后端持有真实 AX 元素，不向旧窗口接口注入虚构窗口编号。
nonisolated enum AccessibilityMenuBarBackend {
    static var isRequired: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27
    }

    struct Host: Sendable {
        let pid: pid_t
        let name: String
        var bundleID: String?
    }

    struct Item: Identifiable, Sendable {
        // 标识只在当前快照内使用，不用于跨进程重启保存布局。
        let id: String
        let host: Host
        let title: String
        var identifier: String?
        let frame: CGRect
        let element: UIElement
    }

    struct Snapshot: Sendable {
        var items: [Item] = []
        var completedHosts = Set<pid_t>()
        var unavailableHosts = 0
        var reachedDeadline = false
    }

    static func displayTitle(appName: String, title: String?, identifier: String?, index: Int) -> String {
        for candidate in [title, identifier] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return candidate
            }
        }
        return "\(appName) · 项目 \(index + 1)"
    }

    static func isValidFrame(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && frame.size.width > 0 && frame.size.height > 0
    }

    /// AX 与 CGDisplayBounds 都使用左上角原点；不将屏幕底部的溢出元素误判为菜单栏项目。
    static func isInMenuBar(_ frame: CGRect, strips: [CGRect]) -> Bool {
        isValidFrame(frame) && strips.contains { $0.contains(frame) }
    }

    static func scan(hosts: [Host]) async -> Snapshot {
        // AX 消息可能等待其他进程；显式移出主线程，并限制每个消息的等待时间。
        let work = Task.detached(priority: .utility) {
            var snapshot = Snapshot()
            let deadline = ContinuousClock.now + .seconds(8)
            for host in hosts {
                guard !Task.isCancelled, ContinuousClock.now < deadline else {
                    snapshot.reachedDeadline = true
                    break
                }
                guard let app = Application(forKnownProcessID: host.pid) else { continue }
                try? app.setMessagingTimeout(0.15)
                guard let bar = AXHelpers.extrasMenuBar(for: app) else { continue }
                try? bar.setMessagingTimeout(0.15)
                let children: [UIElement]
                do {
                    children = try bar.arrayAttribute(.children) ?? []
                } catch {
                    snapshot.unavailableHosts += 1
                    continue
                }
                var completed = true
                for (index, element) in children.enumerated() {
                    guard !Task.isCancelled, ContinuousClock.now < deadline else {
                        snapshot.reachedDeadline = true
                        completed = false
                        break
                    }
                    try? element.setMessagingTimeout(0.15)
                    guard let frame = AXHelpers.frame(for: element), isValidFrame(frame) else { continue }
                    // 新系统的标识与描述可能挂在包装元素的下一层。
                    let nested = AXHelpers.children(for: element)
                    let identifier = AXHelpers.identifier(for: element).flatMap { $0.isEmpty ? nil : $0 }
                        ?? nested.compactMap { AXHelpers.identifier(for: $0) }.first(where: { !$0.isEmpty })
                    let description: String? = (try? element.attribute(.description))
                        ?? nested.compactMap { (try? $0.attribute(.description)) as String? }.first
                    let title = AXHelpers.title(for: element).flatMap { $0.isEmpty ? nil : $0 } ?? description
                    snapshot.items.append(Item(
                        id: "\(host.pid):\(index)",
                        host: host,
                        title: displayTitle(
                            appName: host.name,
                            title: title,
                            identifier: identifier,
                            index: index
                        ),
                        identifier: identifier,
                        frame: frame,
                        element: element
                    ))
                }
                if completed { snapshot.completedHosts.insert(host.pid) }
            }
            return snapshot
        }
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    static func activate(_ item: Item) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            // 元素若已失效，AXPress 会失败；不使用过期坐标点击其他项目。
            AXHelpers.press(item.element)
        }.value
    }

    /// 捕获与移动前后读取实时位置，不使用上次扫描的坐标裁剪其他图标。
    struct HostedSlot: Sendable {
        let pid: pid_t
        let identifier: String?
        let frame: CGRect
    }

    /// 只访问宿主窗口及其直接子元素，不遍历其他应用的窗口或菜单内容。
    static func hostedSlots(displayID: CGDirectDisplayID) async -> [HostedSlot]? {
        await Task.detached(priority: .userInitiated) { () -> [HostedSlot]? in
            guard let process = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MenuBarAgent").first,
                  let app = Application(forKnownProcessID: process.processIdentifier) else { return nil }
            try? app.setMessagingTimeout(0.15)
            guard let windows: [UIElement] = try? app.arrayAttribute(.windows) else { return nil }
            let display = CGDisplayBounds(displayID)
            let strip = CGRect(x: display.minX, y: display.minY, width: display.width, height: 48)
            var result = [HostedSlot]()
            for window in windows {
                try? window.setMessagingTimeout(0.15)
                guard let children: [UIElement] = try? window.arrayAttribute(.children) else { continue }
                for wrapper in children {
                    guard !Task.isCancelled else { return nil }
                    try? wrapper.setMessagingTimeout(0.1)
                    guard let frame = AXHelpers.frame(for: wrapper), isInMenuBar(frame, strips: [strip]),
                          let content: [UIElement] = try? wrapper.arrayAttribute(.children), let child = content.first,
                          let pid = try? child.pid() else { continue }
                    let identifier = AXHelpers.identifier(for: child)
                        ?? AXHelpers.children(for: child).compactMap { AXHelpers.identifier(for: $0) }.first
                    result.append(HostedSlot(pid: pid, identifier: identifier, frame: frame))
                }
            }
            return result
        }.value
    }

    /// 应用自己的 AXPosition 可能过期；单图标应用按宿主进程匹配，多图标只接受明确标识。
    static func matchFrames(items: [Item], slots: [HostedSlot]) -> [String: CGRect] {
        let grouped = Dictionary(grouping: items, by: { $0.host.pid })
        var result = [String: CGRect]()
        for (pid, candidates) in grouped {
            let hosted = slots.filter { $0.pid == pid }
            if candidates.count == 1, hosted.count == 1, let item = candidates.first, let slot = hosted.first {
                result[item.id] = slot.frame
                continue
            }
            for item in candidates {
                guard let identifier = item.identifier, !identifier.isEmpty,
                      candidates.count(where: { $0.identifier == identifier }) == 1 else { continue }
                let matches = hosted.filter { $0.identifier == identifier }
                if matches.count == 1 { result[item.id] = matches[0].frame }
            }
        }
        return result
    }

    static func frames(for items: [Item], displayID: CGDirectDisplayID) async -> [String: CGRect] {
        guard let slots = await hostedSlots(displayID: displayID) else { return [:] }
        return matchFrames(items: items, slots: slots)
    }
}
