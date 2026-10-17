//
//  MenuBarItemImageCache+Accessibility.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

extension MenuBarItemImageCache {
    /// 每批只捕获一次宿主窗口；隐藏或正在移动的项目保留最后有效图像。
    @MainActor
    @discardableResult
    func captureAccessibilityImages(sections: [MenuBarSection.Name], displayID: CGDirectDisplayID?) async -> [MenuBarItemTag: CapturedImage] {
        guard let appState else { return [:] }
        let requestedTags = Set(sections.flatMap { appState.itemManager.itemCache[$0] }.map(\.tag))
        var captured = [MenuBarItemTag: CapturedImage]()
        defer {
            // 只清理本批负责的项目，不能让局部刷新清掉另一分区的检测历史。
            for tag in requestedTags where captured[tag] == nil {
                clearAttention(for: tag)
            }
            recordForAttention(captured)
        }
        guard appState.hasPermission(.screenRecording), !sections.isEmpty,
              !appState.itemManager.accessibilityAssignmentInFlight,
              let screen = Self.resolveScreen(preferredDisplayID: preferredCaptureDisplayID(appState: appState, override: displayID))?.screen
        else { return [:] }
        let concealed = MenuBarVisibility27.hiddenBundles(
            assignments: appState.itemManager.accessibilityAssignments,
            expanded: appState.itemManager.accessibilityExpandedSections,
            alwaysHiddenEnabled: appState.settings.advanced.enableAlwaysHiddenSection
        )
        let items = sections.flatMap { appState.itemManager.itemCache[$0] }.filter {
            !concealed.contains($0.accessibilityItem?.host.bundleID ?? "")
        }
        let before = await AccessibilityMenuBarBackend.frames(for: items.compactMap(\.accessibilityItem), displayID: screen.displayID)
        guard let capture = await ScreenCapture.captureMenuBarHostingWindow(displayID: screen.displayID), !Task.isCancelled else { return [:] }
        let after = await AccessibilityMenuBarBackend.frames(for: items.compactMap(\.accessibilityItem), displayID: screen.displayID)
        let validTags = Set(appState.itemManager.itemCache.managedItems.map(\.tag))
        for tag in Array(images.keys) where !validTags.contains(tag) {
            images.removeValue(forKey: tag)
            accessOrder.remove(tag)
        }
        for item in items {
            guard let ax = item.accessibilityItem, let frame = before[ax.id], after[ax.id] == frame,
                  capture.frame.contains(frame), AccessibilityMenuBarBackend.isValidFrame(frame)
            else { continue }
            let rect = CGRect(
                x: (frame.minX - capture.frame.minX) * capture.scale,
                y: (frame.minY - capture.frame.minY) * capture.scale,
                width: frame.width * capture.scale,
                height: frame.height * capture.scale
            ).integral
            guard let image = capture.image.cropping(to: rect), !image.isTransparent(alphaThreshold: 0.05) else { continue }
            images[item.tag] = CapturedImage(cgImage: image, scale: capture.scale)
            updateAccessOrder(for: item.tag)
            captured[item.tag] = images[item.tag]
        }
        if !captured.isEmpty { storeImages(for: screen.displayID, capturedTags: Array(captured.keys)) }
        return captured
    }
}
