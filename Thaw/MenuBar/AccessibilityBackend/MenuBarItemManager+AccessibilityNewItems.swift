//
//  MenuBarItemManager+AccessibilityNewItems.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

extension MenuBarItemManager {
    /// 仅在应用启动后的短时间内密集扫描该进程，慢启动继续由普通轮询接管。
    func discoverAccessibilityItemsAfterLaunch(pid: pid_t) {
        guard pid != ProcessInfo.processInfo.processIdentifier,
              accessibilityLaunchDiscoveryTasks[pid] == nil else { return }
        accessibilityLaunchDiscoveryTasks[pid] = Task { [weak self] in
            defer { self?.accessibilityLaunchDiscoveryTasks.removeValue(forKey: pid) }
            let deadline = ContinuousClock.now + .seconds(5)
            while !Task.isCancelled, ContinuousClock.now < deadline {
                guard NSRunningApplication(processIdentifier: pid)?.isTerminated == false else { return }
                await self?.cacheAccessibilityItems(onlyPID: pid)
                if self?.accessibilityKnownItems.values.contains(where: { $0.ownerPID == pid }) == true { return }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
    }

    /// 首次迁移保留已有布局；重新启动且尚无保存分区的应用也应执行默认放置。
    func registerAccessibilityNewItems(items: [MenuBarItem], runningPIDs: Set<pid_t>, completedPIDs: Set<pid_t>) {
        if let previous = accessibilityObservedPIDs {
            accessibilityArrivingPIDs.formUnion(runningPIDs.subtracting(previous))
        }
        accessibilityObservedPIDs = runningPIDs
        accessibilityArrivingPIDs.formIntersection(runningPIDs)
        if accessibilityNeedsBaseline {
            accessibilityBaselinePIDs = runningPIDs
            accessibilityNeedsBaseline = false
        }
        var savedAssignments = Defaults.store.dictionary(forKey: "macOS27SectionAssignments") as? [String: String] ?? [:]
        var assignmentsChanged = false
        // 固定本批开始前的应用集合，不能让首个图标登记影响同批其他图标的判断。
        let previouslySeenItems = accessibilitySeenItems
        for item in items {
            let bundle = item.accessibilityItem?.host.bundleID ?? ""
            let knownApplication = previouslySeenItems.contains { $0.hasPrefix(bundle + ":") }
            let firstSeen = accessibilitySeenItems.insert(item.uniqueIdentifier).inserted
            // 历史 seen 只是发现记录，不能代表用户已经为该应用保存了位置。
            // 到达进程一直保留至退出，允许菜单栏图标在应用启动后延迟出现。
            let unplacedArrival = accessibilityArrivingPIDs.contains(item.ownerPID)
                && savedAssignments[bundle] == nil
            guard firstSeen || unplacedArrival,
                  !accessibilityBaselinePIDs.contains(item.ownerPID), item.isMovable,
                  !bundle.isEmpty,
                  !bundle.hasPrefix("com.apple."), bundle != Bundle.main.bundleIdentifier
            else { continue }
            // 同一应用已有分区时继承它，不能因新增一个图标搬动该应用的全部图标。
            let section = accessibilityAssignments[bundle].flatMap(MenuBarSection.Name.init(rawValue:))
                ?? (knownApplication && !unplacedArrival ? .visible : effectiveNewItemsSection)
            accessibilityAssignments[bundle] = section.rawValue
            if savedAssignments[bundle] == nil {
                savedAssignments[bundle] = section.rawValue
                assignmentsChanged = true
            }
            // AX 标识从 Item-0 变成具体名称、模块重建或新增模块，都不能重排已有应用。
            guard !knownApplication || unplacedArrival else {
                // 同时撤销旧标识留下的任务，防止旧标识重新出现后迟到地搬动图标。
                accessibilityPendingNewItems = accessibilityPendingNewItems.filter { !$0.key.hasPrefix(bundle + ":") }
                continue
            }
            accessibilityPendingNewItems[item.uniqueIdentifier] = NewItemsPlacement(
                sectionKey: section.rawValue,
                anchorIdentifier: section == effectiveNewItemsSection ? newItemsPlacement.anchorIdentifier : nil,
                relation: section == effectiveNewItemsSection ? newItemsPlacement.relation : .sectionDefault
            )
        }
        accessibilityBaselinePIDs.subtract(completedPIDs)
        accessibilityBaselinePIDs.formIntersection(runningPIDs)
        Defaults.store.set(accessibilitySeenItems.sorted(), forKey: "macOS27SeenItems")
        if assignmentsChanged { Defaults.store.set(savedAssignments, forKey: "macOS27SectionAssignments") }
        discardAccessibilityMultiItemPlacements(items: items)
        persistAccessibilityPendingNewItems()
    }

    /// 多图标应用不逐项自动插到区域边缘；保留系统内部顺序及手动排序入口。
    func discardAccessibilityMultiItemPlacements(items: [MenuBarItem]) {
        var live = accessibilityKnownItems
        for item in items {
            if let id = item.accessibilityItem?.id { live[id] = item }
        }
        let groups = Dictionary(grouping: live.values, by: { $0.accessibilityItem?.host.bundleID ?? "" })
        let multiple = groups.filter { !$0.key.isEmpty && $0.value.count > 1 }.map(\.key)
        accessibilityPendingNewItems = accessibilityPendingNewItems.filter { key, _ in
            !multiple.contains { key.hasPrefix($0 + ":") }
        }
    }

    func persistAccessibilityPendingNewItems() {
        if let data = try? JSONEncoder().encode(accessibilityPendingNewItems) {
            Defaults.store.set(data, forKey: "macOS27PendingNewItems")
        }
    }

    /// 用户手动调整优先于尚未完成的自动放置。
    func cancelAccessibilityNewItems(for bundles: Set<String>) {
        for item in accessibilityKnownItems.values where bundles.contains(item.accessibilityItem?.host.bundleID ?? "") {
            accessibilityPendingNewItems.removeValue(forKey: item.uniqueIdentifier)
        }
        persistAccessibilityPendingNewItems()
    }

    /// 锚点消失时使用该区域的默认边缘；返回的方向与布局中的标记位置一致。
    static nonisolated func accessibilityNewItemAnchor(
        placement: NewItemsPlacement, identifiers: [String], hiddenSectionStartsOnLeft: Bool
    ) -> (identifier: String, before: Bool)? {
        if let anchor = placement.anchorIdentifier, identifiers.contains(anchor), placement.relation != .sectionDefault {
            return (anchor, placement.relation == .leftOfAnchor)
        }
        let before = placement.sectionKey == "visible" || (placement.sectionKey == "hidden" && hiddenSectionStartsOnLeft)
        guard let anchor = before ? identifiers.first : identifiers.last else { return nil }
        return (anchor, before)
    }

    /// 缩短自动放置和手动排序的鼠标行程；系统未确认时退回常规拖动，不牺牲结果校验。
    func placeAccessibilityItemQuickly(_ item: MenuBarItem, beside target: MenuBarItem, before: Bool) async throws {
        do {
            try await commandDragAccessibilityItem(item, after: target, before: before, rapid: true)
        } catch {
            try Task.checkCancellation()
            try await commandDragAccessibilityItem(item, after: target, before: before)
        }
    }

    /// 与区域内排序共用真实宿主坐标和 Command 拖动；未定位或失败的项目保留队列。
    func placeAccessibilityNewItems() async {
        guard NSClassFromString("XCTestCase") == nil, !accessibilityAssignmentInFlight,
              Date() >= accessibilityNewItemsRetryAfter,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
        // 同时处理旧版本留下的队列，避免升级后继续逐项改动多图标应用。
        discardAccessibilityMultiItemPlacements(items: itemCache.managedItems)
        persistAccessibilityPendingNewItems()
        let pending = itemCache.managedItems.filter {
            accessibilityPendingNewItems[$0.uniqueIdentifier] != nil && $0.isMovable
                && !triggerControlledItemIdentifiers.contains($0.tag.tagIdentifier)
        }.sorted { $0.uniqueIdentifier < $1.uniqueIdentifier }
        guard !pending.isEmpty else { return }
        accessibilityLayoutError = nil
        accessibilityAssignmentInFlight = true
        defer { accessibilityAssignmentInFlight = false }
        do {
            try await eventSemaphore.wait(timeout: .seconds(3))
            defer { Task { await eventSemaphore.signal() } }
            // 可见的新图标已有宿主位置，不需要展开隐藏区或等待它重绘。
            if pending.contains(where: { !$0.isOnScreen || accessibilityPendingNewItems[$0.uniqueIdentifier]?.sectionKey != "visible" }) {
                accessibilityVisibility.release()
                try await Task.sleep(for: .milliseconds(250))
            }
            guard let displayID = Bridging.getActiveMenuBarDisplayID() else { return }
            let all = itemCache.managedItems
            let elements = all.compactMap(\.accessibilityItem)
            var failed = false
            for item in pending {
                try Task.checkCancellation()
                guard let placement = accessibilityPendingNewItems[item.uniqueIdentifier],
                      let section = MenuBarSection.Name(rawValue: placement.sectionKey) else { continue }
                let current = accessibilityAssignments[item.accessibilityItem?.host.bundleID ?? ""] ?? "visible"
                guard current == placement.sectionKey else {
                    accessibilityPendingNewItems.removeValue(forKey: item.uniqueIdentifier)
                    continue
                }
                let frames = await AccessibilityMenuBarBackend.frames(for: elements, displayID: displayID)
                guard let ax = item.accessibilityItem, frames[ax.id] != nil else { failed = true; continue }
                let peers = all.filter {
                    $0.uniqueIdentifier != item.uniqueIdentifier
                        && accessibilityPendingNewItems[$0.uniqueIdentifier] == nil
                        && (accessibilityAssignments[$0.accessibilityItem?.host.bundleID ?? ""] ?? "visible") == section.rawValue
                        && $0.accessibilityItem.flatMap { frames[$0.id] } != nil
                }.sorted { ($0.accessibilityItem.flatMap { frames[$0.id] }?.minX ?? 0) < ($1.accessibilityItem.flatMap { frames[$0.id] }?.minX ?? 0) }
                let destination = Self.accessibilityNewItemAnchor(
                    placement: placement,
                    identifiers: peers.map(\.uniqueIdentifier),
                    hiddenSectionStartsOnLeft: appState?.settings.advanced.enableAlwaysHiddenSection == true
                )
                do {
                    if let destination, let target = peers.first(where: { $0.uniqueIdentifier == destination.identifier }) {
                        try await placeAccessibilityItemQuickly(item, beside: target, before: destination.before)
                    } else if section != .visible,
                              let target = all.filter({
                                  (accessibilityAssignments[$0.accessibilityItem?.host.bundleID ?? ""] ?? "visible") == "visible"
                                      && $0.accessibilityItem.flatMap { frames[$0.id] } != nil
                              }).min(by: { ($0.accessibilityItem.flatMap { frames[$0.id] }?.minX ?? 0) < ($1.accessibilityItem.flatMap { frames[$0.id] }?.minX ?? 0) })
                    {
                        // 空隐藏区域以显示区域左边缘为起点。
                        try await placeAccessibilityItemQuickly(item, beside: target, before: true)
                    }
                    accessibilityPendingNewItems.removeValue(forKey: item.uniqueIdentifier)
                } catch { failed = true }
            }
            if failed {
                accessibilityNewItemsRetryAfter = Date().addingTimeInterval(30)
                accessibilityLayoutError = "部分新菜单栏项目暂时无法定位，将稍后重试。"
            }
            persistAccessibilityPendingNewItems()
        } catch {
            accessibilityNewItemsRetryAfter = Date().addingTimeInterval(30)
            accessibilityLayoutError = "新菜单栏项目放置失败，将稍后重试。"
        }
    }
}
