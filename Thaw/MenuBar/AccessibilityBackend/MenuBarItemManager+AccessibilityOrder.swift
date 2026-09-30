//
//  MenuBarItemManager+AccessibilityOrder.swift
//  Project: Thaw
//
//  Copyright (Ice) © 2023–2025 Jordan Baird
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

extension MenuBarItemManager {
    /// 使用系统支持的 Command 拖动，不向 macOS 27 的空窗口编号投递事件。
    /// 时序参照上游 macos-27-preview.3 的 SyntheticMoveEngine。
    func reorderAccessibilityItems(_ desired: [MenuBarItem], in section: MenuBarSection.Name) {
        Task { await restoreAccessibilityOrder(desired, in: section) }
    }

    /// 等待实际排序完成，供配置恢复和手动排序共用；不保存未经系统确认的顺序。
    @discardableResult
    func restoreAccessibilityOrder(_ desired: [MenuBarItem], in section: MenuBarSection.Name) async -> Bool {
        guard !accessibilityAssignmentInFlight,
              desired.allSatisfy({ itemCache.address(for: $0.tag)?.section == section }) else { return false }
        guard desired.count > 1 else { return true }
        accessibilityAssignmentInFlight = true
        cancelAccessibilityNewItems(for: Set(desired.compactMap { $0.accessibilityItem?.host.bundleID }))
        var succeeded = false
        do {
            try await eventSemaphore.wait(timeout: .seconds(3))
            defer { Task { await eventSemaphore.signal() } }
            accessibilityVisibility.release()
            try await Task.sleep(for: .milliseconds(300))
            guard let displayID = Bridging.getActiveMenuBarDisplayID() else { throw EventError.cannotComplete }
            let live = await AccessibilityMenuBarBackend.frames(for: itemCache.managedItems.compactMap(\.accessibilityItem), displayID: displayID)
            // 无法定位的项目留在原处，继续排序其余项目，但不能报告完整成功。
            let resolved = desired.filter { $0.accessibilityItem.map { live[$0.id] != nil } == true }
            guard resolved.count > 1 else { throw EventError.cannotComplete }
            for index in 1..<resolved.count {
                try Task.checkCancellation()
                let item = resolved[index]
                let target = resolved[index - 1]
                if item.isMovable {
                    try await commandDragAccessibilityItem(item, after: target)
                } else if target.isMovable {
                    try await commandDragAccessibilityItem(target, after: item, before: true)
                }
            }
            let confirmed = await AccessibilityMenuBarBackend.frames(for: itemCache.managedItems.compactMap(\.accessibilityItem), displayID: displayID)
            let orderedFrames = resolved.compactMap { $0.accessibilityItem.flatMap { confirmed[$0.id] } }
            guard orderedFrames.count == resolved.count,
                  zip(orderedFrames, orderedFrames.dropFirst()).allSatisfy({ $0.minX < $1.minX && abs($0.midY - $1.midY) < 4 }) else {
                throw EventError.cannotComplete
            }
            succeeded = resolved.count == desired.count
            accessibilityLayoutError = succeeded ? nil : "部分项目未能定位，已保留其原位置。其余项目已排序。"
        } catch {
            accessibilityLayoutError = "系统未确认完整排序结果，请展开菜单栏项目后重试。"
        }
        lastMoveOperationTimestamp = .now
        await cacheAccessibilityItems()
        accessibilityAssignmentInFlight = false
        let orderError = accessibilityLayoutError
        // 等到隐藏状态恢复后再交给下一分区，避免多个排序事务交叉。
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            applyAccessibilityVisibility { [weak self] error in
                if error == nil, self?.accessibilityLayoutError == nil { self?.accessibilityLayoutError = orderError }
                continuation.resume()
            }
        }
        return succeeded
    }

    /// 将配置中的稳定标识映射到当前项目，未记录的新项目保持原有相对顺序。
    nonisolated static func accessibilityProfileOrder(saved: [String], current: [String]) -> [String] {
        let available = Set(current)
        var seen = Set<String>()
        let matched = saved.filter { available.contains($0) && seen.insert($0).inserted }
        return matched + current.filter { seen.insert($0).inserted }
    }

    /// 展开后维持分区边界：只移动隐藏项目，显示项目的相对顺序不变。
    func enforceAccessibilitySectionBoundary() async throws {
        guard NSClassFromString("XCTestCase") == nil, !accessibilityExpandedSections.isEmpty,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        let previousBusy = accessibilityAssignmentInFlight
        accessibilityAssignmentInFlight = true
        defer { accessibilityAssignmentInFlight = previousBusy }
        try await eventSemaphore.wait(timeout: .seconds(3))
        defer { Task { await eventSemaphore.signal() } }
        guard let displayID = Bridging.getActiveMenuBarDisplayID() else { return }
        let all = itemCache.managedItems
        let elements = all.compactMap(\.accessibilityItem)
        var frames = await AccessibilityMenuBarBackend.frames(for: elements, displayID: displayID)
        func frame(_ item: MenuBarItem) -> CGRect? { item.accessibilityItem.flatMap { frames[$0.id] } }
        let visible = all.filter {
            (accessibilityAssignments[$0.accessibilityItem?.host.bundleID ?? ""].flatMap(MenuBarSection.Name.init(rawValue:)) ?? .visible) == .visible
        }.filter { frame($0) != nil }
        guard var anchor = visible.min(by: { (frame($0)?.minX ?? 0) < (frame($1)?.minX ?? 0) }) else { return }
        let hidden = all.filter { item in
            let raw = accessibilityAssignments[item.accessibilityItem?.host.bundleID ?? ""] ?? "visible"
            guard var section = MenuBarSection.Name(rawValue: raw), section != .visible else { return false }
            if section == .alwaysHidden, appState?.settings.advanced.enableAlwaysHiddenSection != true { section = .hidden }
            // 系统溢出或无法唯一匹配宿主的项目没有可操作位置，不阻断其他项目。
            return accessibilityExpandedSections.contains(section) && item.isMovable && frame(item) != nil
        }.sorted { (frame($0)?.minX ?? $0.bounds.minX) < (frame($1)?.minX ?? $1.bounds.minX) }
        for item in hidden.reversed() {
            guard let source = frame(item), let target = frame(anchor) else { throw EventError.cannotComplete }
            if !Self.accessibilityHiddenItemPrecedesVisible(source, target) {
                try await commandDragAccessibilityItem(item, after: anchor, before: true)
                frames = await AccessibilityMenuBarBackend.frames(for: elements, displayID: displayID)
            }
            anchor = item
        }
    }

    nonisolated static func accessibilityHiddenItemPrecedesVisible(_ hidden: CGRect, _ visible: CGRect) -> Bool {
        AccessibilityMenuBarBackend.isValidFrame(hidden) && AccessibilityMenuBarBackend.isValidFrame(visible)
            && abs(hidden.midY - visible.midY) < 4 && hidden.maxX <= visible.minX + 1
    }

    func stepAccessibilityItem(_ item: MenuBarItem, offset: Int) {
        guard let section = itemCache.address(for: item.tag)?.section else { return }
        var order = itemCache[section]
        guard let index = order.firstIndex(where: { $0.presentationID == item.presentationID }),
              order.indices.contains(index + offset), order[index + offset].isMovable else { return }
        order.swapAt(index, index + offset)
        let lower = min(index, index + offset)
        reorderAccessibilityItems(Array(order[lower...(lower + 1)]), in: section)
    }

    func commandDragAccessibilityItem(_ item: MenuBarItem, after target: MenuBarItem, before: Bool = false) async throws {
        guard let ax = item.accessibilityItem, let anchor = target.accessibilityItem else { throw EventError.cannotComplete }
        let strips = NSScreen.screens.map { screen in
            let frame = CGDisplayBounds(screen.displayID)
            return CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: max(40, screen.getMenuBarHeightEstimate()))
        }
        let elements = itemCache.managedItems.compactMap(\.accessibilityItem)
        guard let displayID = Bridging.getActiveMenuBarDisplayID() else { throw EventError.cannotComplete }
        let frames = await AccessibilityMenuBarBackend.frames(for: elements, displayID: displayID)
        guard let from = frames[ax.id], let to = frames[anchor.id],
              strips.contains(where: { $0.contains(from) && $0.contains(to) }) else { throw EventError.cannotComplete }
        // 已经相邻时不发送事件，减少整区排序的移动次数。
        if Self.accessibilityOrderIsAdjacent(frames: frames, item: before ? anchor.id : ax.id, after: before ? ax.id : anchor.id) { return }
        guard let source = CGEventSource(stateID: .hidSystemState), let cursor = CGEvent(source: nil)?.location else { throw EventError.cannotComplete }
        let start = CGPoint(x: from.midX, y: from.midY)
        let end = CGPoint(x: before ? to.minX - 2 : to.maxX + 2, y: to.midY)
        guard strips.contains(where: { $0.contains(end) }) else { throw EventError.cannotComplete }
        func post(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
        var dropped = false
        defer {
            if !dropped { post(.leftMouseUp, end) }
            MouseHelpers.warpCursor(to: cursor)
        }
        post(.mouseMoved, start)
        try await Task.sleep(for: .milliseconds(30))
        post(.leftMouseDown, start)
        try await Task.sleep(for: .milliseconds(60))
        for step in 1...24 {
            let progress = CGFloat(step) / 24
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
            try await Task.sleep(for: .milliseconds(16))
        }
        post(.leftMouseUp, end)
        dropped = true
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(150))
            let fresh = await AccessibilityMenuBarBackend.frames(for: elements, displayID: displayID)
            if Self.accessibilityOrderIsAdjacent(frames: fresh, item: before ? anchor.id : ax.id, after: before ? ax.id : anchor.id) { return }
        }
        throw EventError.cannotComplete
    }

    nonisolated static func accessibilityOrderIsAdjacent(frames: [String: CGRect], item: String, after anchor: String) -> Bool {
        guard let from = frames[item], let to = frames[anchor], from.minX >= to.maxX - 1,
              abs(from.midY - to.midY) < 4 else { return false }
        return !frames.contains { key, frame in
            key != item && key != anchor && abs(frame.midY - to.midY) < 4
                && frame.midX > to.midX && frame.midX < from.midX
        }
    }
}
