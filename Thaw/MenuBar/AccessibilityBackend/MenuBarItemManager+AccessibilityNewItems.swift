import AppKit

extension MenuBarItemManager {
    /// 首次迁移只登记现有项目；后续使用稳定标识识别新项目，避免应用重启后重复搬动。
    func registerAccessibilityNewItems(items: [MenuBarItem], runningPIDs: Set<pid_t>, completedPIDs: Set<pid_t>) {
        if accessibilityNeedsBaseline {
            accessibilityBaselinePIDs = runningPIDs
            accessibilityNeedsBaseline = false
        }
        var savedAssignments = Defaults.store.dictionary(forKey: "macOS27SectionAssignments") as? [String: String] ?? [:]
        var assignmentsChanged = false
        for item in items {
            let bundle = item.accessibilityItem?.host.bundleID ?? ""
            let knownApplication = accessibilitySeenItems.contains { $0.hasPrefix(bundle + ":") }
            guard accessibilitySeenItems.insert(item.uniqueIdentifier).inserted,
                  !accessibilityBaselinePIDs.contains(item.ownerPID), item.isMovable,
                  !bundle.isEmpty,
                  !bundle.hasPrefix("com.apple."), bundle != Bundle.main.bundleIdentifier
            else { continue }
            // 同一应用已有分区时继承它，不能因新增一个图标搬动该应用的全部图标。
            let section = accessibilityAssignments[bundle].flatMap(MenuBarSection.Name.init(rawValue:))
                ?? (knownApplication ? .visible : effectiveNewItemsSection)
            accessibilityAssignments[bundle] = section.rawValue
            if savedAssignments[bundle] == nil {
                savedAssignments[bundle] = section.rawValue
                assignmentsChanged = true
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
        persistAccessibilityPendingNewItems()
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
    nonisolated static func accessibilityNewItemAnchor(
        placement: NewItemsPlacement, identifiers: [String], hiddenSectionStartsOnLeft: Bool
    ) -> (identifier: String, before: Bool)? {
        if let anchor = placement.anchorIdentifier, identifiers.contains(anchor), placement.relation != .sectionDefault {
            return (anchor, placement.relation == .leftOfAnchor)
        }
        let before = placement.sectionKey == "visible" || (placement.sectionKey == "hidden" && hiddenSectionStartsOnLeft)
        guard let anchor = before ? identifiers.first : identifiers.last else { return nil }
        return (anchor, before)
    }

    /// 与区域内排序共用真实宿主坐标和 Command 拖动；未定位或失败的项目保留队列。
    func placeAccessibilityNewItems() async {
        guard NSClassFromString("XCTestCase") == nil, !accessibilityAssignmentInFlight,
              Date() >= accessibilityNewItemsRetryAfter,
              !CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
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
            accessibilityVisibility.release()
            try await Task.sleep(for: .milliseconds(250))
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
                }.sorted { frames[$0.accessibilityItem!.id]!.minX < frames[$1.accessibilityItem!.id]!.minX }
                let destination = Self.accessibilityNewItemAnchor(
                    placement: placement, identifiers: peers.map(\.uniqueIdentifier),
                    hiddenSectionStartsOnLeft: appState?.settings.advanced.enableAlwaysHiddenSection == true
                )
                do {
                    if let destination, let target = peers.first(where: { $0.uniqueIdentifier == destination.identifier }) {
                        try await commandDragAccessibilityItem(item, after: target, before: destination.before)
                    } else if section != .visible,
                              let target = all.filter({
                                  (accessibilityAssignments[$0.accessibilityItem?.host.bundleID ?? ""] ?? "visible") == "visible"
                                      && $0.accessibilityItem.flatMap { frames[$0.id] } != nil
                              }).min(by: { frames[$0.accessibilityItem!.id]!.minX < frames[$1.accessibilityItem!.id]!.minX }) {
                        // 空隐藏区域以显示区域左边缘为起点。
                        try await commandDragAccessibilityItem(item, after: target, before: true)
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
