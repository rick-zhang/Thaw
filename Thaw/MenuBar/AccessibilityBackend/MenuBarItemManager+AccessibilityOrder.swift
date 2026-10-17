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
    func reorderAccessibilityItems(_ desired: [MenuBarItem], in section: MenuBarSection.Name, moving item: MenuBarItem? = nil) {
        Task { await restoreAccessibilityOrder(desired, in: section, moving: item) }
    }

    /// 等待实际排序完成，供配置恢复和手动排序共用；不保存未经系统确认的顺序。
    @discardableResult
    func restoreAccessibilityOrder(_ desired: [MenuBarItem], in section: MenuBarSection.Name, moving item: MenuBarItem? = nil) async -> Bool {
        guard !accessibilityAssignmentInFlight,
              desired.allSatisfy({ itemCache.address(for: $0.tag)?.section == section }) else { return false }
        guard desired.count > 1 else { return true }
        accessibilityAssignmentInFlight = true
        cancelAccessibilityNewItems(for: Set(desired.compactMap { $0.accessibilityItem?.host.bundleID }))
        var succeeded = false
        var releasedVisibility = false
        do {
            try await eventSemaphore.wait(timeout: .seconds(3))
            defer { Task { await eventSemaphore.signal() } }
            guard let displayID = Bridging.getActiveMenuBarDisplayID() else { throw EventError.cannotComplete }
            var live = await AccessibilityMenuBarBackend.frames(for: itemCache.managedItems.compactMap(\.accessibilityItem), displayID: displayID)
            // 只在目标项目无法直接定位时展开；可见区排序不扰动隐藏区。
            if !desired.allSatisfy({ $0.accessibilityItem.map { live[$0.id] != nil } == true }) {
                accessibilityVisibility.release()
                releasedVisibility = true
                try await Task.sleep(for: .milliseconds(300))
                live = await AccessibilityMenuBarBackend.frames(for: itemCache.managedItems.compactMap(\.accessibilityItem), displayID: displayID)
            }
            // 无法定位的项目留在原处，继续排序其余项目，但不能报告完整成功。
            let resolved = desired.filter { $0.accessibilityItem.map { live[$0.id] != nil } == true }
            guard resolved.count > 1 else { throw EventError.cannotComplete }
            let current = resolved.sorted {
                ($0.accessibilityItem.flatMap { live[$0.id] }?.minX ?? 0) < ($1.accessibilityItem.flatMap { live[$0.id] }?.minX ?? 0)
            }
            if current.map(\.uniqueIdentifier) == resolved.map(\.uniqueIdentifier) {
                // 已经满足目标顺序，不再发送拖动事件。
            } else if let item, item.isMovable,
                      let destination = Self.accessibilitySingleMoveDestination(
                          current: current.map(\.uniqueIdentifier), desired: resolved.map(\.uniqueIdentifier), moving: item.uniqueIdentifier
                      ), let target = resolved.first(where: { $0.uniqueIdentifier == destination.anchor })
            {
                // 单项拖放只移动被拖动项；其他成员顺序不匹配时保留整区恢复路径。
                try await placeAccessibilityItemQuickly(item, beside: target, before: destination.before)
            } else {
                for index in 1 ..< resolved.count {
                    try Task.checkCancellation()
                    let item = resolved[index]
                    let target = resolved[index - 1]
                    if item.isMovable {
                        try await placeAccessibilityItemQuickly(item, beside: target, before: false)
                    } else if target.isMovable {
                        try await placeAccessibilityItemQuickly(target, beside: item, before: true)
                    }
                }
            }
            let confirmed = await AccessibilityMenuBarBackend.frames(for: itemCache.managedItems.compactMap(\.accessibilityItem), displayID: displayID)
            let orderedFrames = resolved.compactMap { $0.accessibilityItem.flatMap { confirmed[$0.id] } }
            guard orderedFrames.count == resolved.count,
                  zip(orderedFrames, orderedFrames.dropFirst()).allSatisfy({ $0.minX < $1.minX && abs($0.midY - $1.midY) < 4 })
            else {
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
        if releasedVisibility {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                applyAccessibilityVisibility { [weak self] error in
                    if error == nil, self?.accessibilityLayoutError == nil { self?.accessibilityLayoutError = orderError }
                    continuation.resume()
                }
            }
        }
        return succeeded
    }

    /// 只有其余项目的相对顺序一致时，才可用一次拖动完成目标顺序。
    static nonisolated func accessibilitySingleMoveDestination(
        current: [String], desired: [String], moving: String
    ) -> (anchor: String, before: Bool)? {
        guard desired.count > 1, Set(desired).count == desired.count,
              current.count == desired.count, Set(current) == Set(desired),
              current.filter({ $0 != moving }) == desired.filter({ $0 != moving }),
              let index = desired.firstIndex(of: moving) else { return nil }
        return index == 0 ? (desired[1], true) : (desired[index - 1], false)
    }

    /// 将配置中的稳定标识映射到当前项目，未记录的新项目保持原有相对顺序。
    static nonisolated func accessibilityProfileOrder(saved: [String], current: [String]) -> [String] {
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

    static nonisolated func accessibilityHiddenItemPrecedesVisible(_ hidden: CGRect, _ visible: CGRect) -> Bool {
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
        reorderAccessibilityItems(Array(order[lower ... (lower + 1)]), in: section, moving: item)
    }

    func commandDragAccessibilityItem(_ item: MenuBarItem, after target: MenuBarItem, before: Bool = false, rapid: Bool = false) async throws {
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
        let steps = rapid ? 8 : 24
        for step in 1 ... steps {
            let progress = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, CGPoint(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress))
            try await Task.sleep(for: .milliseconds(rapid ? 12 : 16))
        }
        post(.leftMouseUp, end)
        dropped = true
        for _ in 0 ..< 5 {
            try await Task.sleep(for: .milliseconds(150))
            let fresh = await AccessibilityMenuBarBackend.frames(for: elements, displayID: displayID)
            if Self.accessibilityOrderIsAdjacent(frames: fresh, item: before ? anchor.id : ax.id, after: before ? ax.id : anchor.id) { return }
        }
        throw EventError.cannotComplete
    }

    static nonisolated func accessibilityOrderIsAdjacent(frames: [String: CGRect], item: String, after anchor: String) -> Bool {
        guard let from = frames[item], let to = frames[anchor], from.minX >= to.maxX - 1,
              abs(from.midY - to.midY) < 4 else { return false }
        return !frames.contains { key, frame in
            key != item && key != anchor && abs(frame.midY - to.midY) < 4
                && frame.midX > to.midX && frame.midX < from.midX
        }
    }
}
