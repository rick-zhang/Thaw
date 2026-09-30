//
//  MenuBarItemManager+Accessibility.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

extension MenuBarItemManager {
    /// 统一搜索、热键、布局和 Thaw Bar 的打开路径，避免向空窗口编号发送事件。
    func activateAccessibilityItem(_ item: MenuBarItem) async -> Bool {
        guard !accessibilityAssignmentInFlight, let ax = item.accessibilityItem, !Task.isCancelled else { return false }
        accessibilityAssignmentInFlight = true
        defer { accessibilityAssignmentInFlight = false }
        accessibilityExpandedSections = [.hidden, .alwaysHidden]
        accessibilityVisibility.release()
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return false }
        do { try await enforceAccessibilitySectionBoundary() } catch {
            accessibilityLayoutError = "隐藏图标排序失败，请展开所有项目后重试。"
            return false
        }
        let current = accessibilityKnownItems[ax.id]?.accessibilityItem ?? ax
        let success = await AccessibilityMenuBarBackend.activate(current)
        accessibilityLayoutError = success ? nil : "无法打开项目，请刷新布局后重试。"
        return success
    }

    func cacheAccessibilityItems() async {
        guard NSClassFromString("XCTestCase") == nil, !accessibilityScanRunning, AXHelpers.isProcessTrusted() else { return }
        accessibilityScanRunning = true
        defer { accessibilityScanRunning = false }
        accessibilityLastScan = Date()
        let apps = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
        }
        let hosts = apps.map {
            AccessibilityMenuBarBackend.Host(pid: $0.processIdentifier, name: $0.localizedName ?? "未知应用", bundleID: $0.bundleIdentifier)
        }
        let snapshot = await AccessibilityMenuBarBackend.scan(hosts: hosts)
        guard !Task.isCancelled else { return }
        let activePIDs = Set(apps.map(\.processIdentifier))
        let detectedIDs = Set(snapshot.items.map(\.id))
        let concealed = MenuBarVisibility27.hiddenBundles(
            assignments: accessibilityAssignments, expanded: accessibilityExpandedSections,
            alwaysHiddenEnabled: appState?.settings.advanced.enableAlwaysHiddenSection == true
        )
        accessibilityKnownItems = accessibilityKnownItems.filter { id, item in
            guard activePIDs.contains(item.ownerPID) else { return false }
            // 完整扫描后删除已消失的可见项目；隐藏或扫描失败的应用保留旧项目以便恢复。
            return detectedIDs.contains(id)
                || !snapshot.completedHosts.contains(item.ownerPID)
                || concealed.contains(item.accessibilityItem?.host.bundleID ?? "")
        }
        let strips = NSScreen.screens.map { screen in
            let bounds = CGDisplayBounds(screen.displayID)
            return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: max(40, screen.getMenuBarHeightEstimate()))
        }
        let displayID = Bridging.getActiveMenuBarDisplayID() ?? CGMainDisplayID()
        let hostedFrames = await AccessibilityMenuBarBackend.frames(for: snapshot.items, displayID: displayID)
        let tags = AccessibilityMenuBarBackend.tags(for: snapshot.items)
        for ax in snapshot.items {
            guard let tag = tags[ax.id] else { continue }
            let item = MenuBarItem(
                tag: tag,
                accessibilityItem: ax,
                windowID: kCGNullWindowID,
                ownerPID: ax.host.pid,
                sourcePID: ax.host.pid,
                bounds: hostedFrames[ax.id] ?? accessibilityKnownItems[ax.id]?.bounds ?? ax.frame,
                title: ax.title,
                isOnScreen: !concealed.contains(ax.host.bundleID ?? "") && hostedFrames[ax.id].map { AccessibilityMenuBarBackend.isInMenuBar($0, strips: strips) } == true
            )
            accessibilityKnownItems[ax.id] = item
        }
        if !accessibilityAssignmentInFlight {
            registerAccessibilityNewItems(
                items: snapshot.items.compactMap { accessibilityKnownItems[$0.id] },
                runningPIDs: activePIDs, completedPIDs: snapshot.completedHosts
            )
        }
        publishAccessibilityItems()
        if !accessibilityAssignmentInFlight {
            await placeAccessibilityNewItems()
            let placementError = accessibilityLayoutError
            applyAccessibilityVisibility { [weak self] error in
                if error == nil, self?.accessibilityLayoutError == nil {
                    self?.accessibilityLayoutError = placementError
                }
            }
        }
        completedCacheCycles += 1
    }

    func publishAccessibilityItems() {
        var cache = ItemCache(displayID: Bridging.getActiveMenuBarDisplayID())
        for item in accessibilityKnownItems.values.sorted(by: { $0.bounds.minX < $1.bounds.minX }) {
            let bundle = item.accessibilityItem?.host.bundleID ?? ""
            var section = accessibilityAssignments[bundle].flatMap(MenuBarSection.Name.init(rawValue:)) ?? .visible
            if section == .alwaysHidden, appState?.settings.advanced.enableAlwaysHiddenSection != true {
                section = .hidden
            }
            cache[section].append(item)
        }
        itemCache = cache
        areControlItemsMissing = false
    }

    func applyAccessibilityVisibility(completion: (@MainActor (Error?) -> Void)? = nil) {
        let hidden = MenuBarVisibility27.hiddenBundles(
            assignments: accessibilityAssignments,
            expanded: accessibilityExpandedSections,
            alwaysHiddenEnabled: appState?.settings.advanced.enableAlwaysHiddenSection == true
        )
        accessibilityVisibility.apply(hiddenBundles: hidden) { [weak self] error in
            guard let self else { completion?(error); return }
            guard error == nil, !self.accessibilityExpandedSections.isEmpty else {
                self.accessibilityLayoutError = error?.localizedDescription
                completion?(error)
                return
            }
            guard Date() >= self.accessibilityBoundaryRetryAfter else { completion?(nil); return }
            let wasBusy = self.accessibilityAssignmentInFlight
            self.accessibilityAssignmentInFlight = true
            Task { @MainActor in
                do {
                    if wasBusy { try await Task.sleep(for: .milliseconds(200)) }
                    try await self.enforceAccessibilitySectionBoundary()
                    self.accessibilityLayoutError = nil
                } catch {
                    self.accessibilityBoundaryRetryAfter = Date().addingTimeInterval(15)
                    self.accessibilityLayoutError = "部分隐藏图标未能移到显示图标左侧，请确认菜单栏有足够空间后重试。"
                }
                // 隐藏接口已成功；排序失败保留当前展开状态，不制造界面与系统状态不一致。
                self.accessibilityAssignmentInFlight = wasBusy
                completion?(nil)
            }
        }
    }

    func assignAccessibilityItem(_ item: MenuBarItem, to section: MenuBarSection.Name) {
        guard !accessibilityAssignmentInFlight else { return }
        guard let bundle = item.accessibilityItem?.host.bundleID, !bundle.hasPrefix("com.apple.") else { return }
        if itemCache.address(for: item.tag)?.section == section {
            accessibilityLayoutError = nil
            publishAccessibilityItems()
            return
        }
        accessibilityAssignmentInFlight = true
        let previous = accessibilityAssignments
        let unit = appState?.itemGroupManager.dragUnit(for: item, in: itemCache.managedItems) ?? [item]
        let bundles = Set(unit.compactMap { $0.accessibilityItem?.host.bundleID }).union([bundle])
        for groupedBundle in bundles where !groupedBundle.hasPrefix("com.apple.") {
            accessibilityAssignments[groupedBundle] = section.rawValue
        }
        applyAccessibilityVisibility { [weak self] error in
            guard let self else { return }
            self.accessibilityAssignmentInFlight = false
            if error != nil {
                self.accessibilityAssignments = previous
            } else {
                Defaults.store.set(self.accessibilityAssignments, forKey: "macOS27SectionAssignments")
                self.cancelAccessibilityNewItems(for: bundles)
            }
            self.publishAccessibilityItems()
        }
    }

    /// 配置恢复及自动化共用分区事务；自动化的临时状态不写入用户配置。
    func commitAccessibilityAssignments(_ assignments: [String: String], persist: Bool = true) async -> Bool {
        guard !accessibilityAssignmentInFlight, !Task.isCancelled else { return false }
        accessibilityAssignmentInFlight = true
        let previous = accessibilityAssignments
        accessibilityAssignments = assignments
        return await withCheckedContinuation { continuation in
            applyAccessibilityVisibility { [weak self] error in
                guard let self else { continuation.resume(returning: false); return }
                self.accessibilityAssignmentInFlight = false
                if error != nil {
                    self.accessibilityAssignments = previous
                } else if persist {
                    Defaults.store.set(assignments, forKey: "macOS27SectionAssignments")
                    self.accessibilityPendingNewItems.removeAll()
                    self.persistAccessibilityPendingNewItems()
                }
                self.publishAccessibilityItems()
                continuation.resume(returning: error == nil)
            }
        }
    }

    func setAccessibilitySection(_ section: MenuBarSection.Name, expanded: Bool) {
        guard !accessibilityAssignmentInFlight else { return }
        accessibilityAssignmentInFlight = true
        accessibilityBoundaryRetryAfter = .distantPast
        let previous = accessibilityExpandedSections
        let section: MenuBarSection.Name = section == .visible ? .hidden : section
        if expanded {
            accessibilityExpandedSections.insert(section)
            if section == .alwaysHidden { accessibilityExpandedSections.insert(.hidden) }
        } else {
            accessibilityExpandedSections.removeAll()
        }
        applyAccessibilityVisibility { [weak self] error in
            guard let self else { return }
            self.accessibilityAssignmentInFlight = false
            if error != nil {
                self.accessibilityExpandedSections = previous
            }
        }
    }
}
