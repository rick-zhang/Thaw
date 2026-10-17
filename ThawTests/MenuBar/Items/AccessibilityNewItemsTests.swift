import AppKit
import AXSwift6
import Testing
@testable import Thaw

@MainActor
struct AccessibilityNewItemsTests {
    private func item(_ bundle: String, pid: pid_t, title: String = "item") -> MenuBarItem {
        let frame = CGRect(x: 500, y: 0, width: 30, height: 30)
        let ax = AccessibilityMenuBarBackend.Item(
            id: "\(pid):\(title)",
            host: .init(pid: pid, name: bundle, bundleID: bundle), title: title, frame: frame,
            element: UIElement(AXUIElementCreateApplication(pid))
        )
        return MenuBarItem(tag: .init(namespace: .string(bundle), title: title), accessibilityItem: ax,
                           windowID: 0, ownerPID: pid, sourcePID: pid, bounds: frame, title: title, isOnScreen: true)
    }

    @Test("首次登记不搬动现有项目，延迟响应的进程仍属于迁移基线")
    func migrationBaseline() throws {
        try withScratchDefaults { _ in
            let manager = MenuBarItemManager()
            manager.registerAccessibilityNewItems(items: [item("test.old", pid: 101)], runningPIDs: [101, 102], completedPIDs: [101])
            manager.registerAccessibilityNewItems(items: [item("test.late", pid: 102)], runningPIDs: [101, 102], completedPIDs: [102])
            #expect(manager.accessibilityPendingNewItems.isEmpty)
            #expect(manager.accessibilityAssignments.isEmpty)
        }
    }

    @Test("新项目保存分区和锚点，重启不重复识别，队列可恢复")
    func discoveryAndRelaunch() throws {
        try withScratchDefaults { _ in
            let manager = MenuBarItemManager()
            manager.registerAccessibilityNewItems(items: [], runningPIDs: [], completedPIDs: [])
            manager.newItemsPlacement = .init(sectionKey: "hidden", anchorIdentifier: "test.anchor:item", relation: .rightOfAnchor)
            let fresh = item("test.new", pid: 103)
            manager.registerAccessibilityNewItems(items: [fresh], runningPIDs: [103], completedPIDs: [103])
            #expect(manager.accessibilityAssignments["test.new"] == "hidden")
            #expect(manager.accessibilityPendingNewItems[fresh.uniqueIdentifier] == manager.newItemsPlacement)
            let restored = MenuBarItemManager()
            #expect(restored.accessibilityPendingNewItems == manager.accessibilityPendingNewItems)
            restored.accessibilityPendingNewItems.removeAll()
            restored.registerAccessibilityNewItems(items: [item("test.new", pid: 104)], runningPIDs: [104], completedPIDs: [104])
            #expect(restored.accessibilityPendingNewItems.isEmpty)
        }
    }

    @Test("历史已见但未保存分区的 Docker 再启动后按标记定位，延迟图标也能处理", arguments: ["visible", "hidden"])
    func previouslySeenUnassignedApplicationArrivesLater(section: String) throws {
        try withScratchDefaults { defaults in
            let docker = item("com.electron.dockerdesktop", pid: 111)
            defaults.set([docker.uniqueIdentifier], forKey: "macOS27SeenItems")
            let manager = MenuBarItemManager()
            manager.registerAccessibilityNewItems(items: [], runningPIDs: [100], completedPIDs: [100])
            manager.newItemsPlacement = .init(sectionKey: section, anchorIdentifier: "test.anchor:item", relation: .leftOfAnchor)
            // 先发现进程，后一次扫描才发现图标。
            manager.registerAccessibilityNewItems(items: [], runningPIDs: [100, 111], completedPIDs: [100])
            manager.registerAccessibilityNewItems(items: [docker], runningPIDs: [100, 111], completedPIDs: [111])
            #expect(manager.accessibilityPendingNewItems[docker.uniqueIdentifier] == manager.newItemsPlacement)
            #expect((defaults.dictionary(forKey: "macOS27SectionAssignments") as? [String: String])?["com.electron.dockerdesktop"] == section)
            manager.accessibilityPendingNewItems.removeAll()
            manager.registerAccessibilityNewItems(items: [docker], runningPIDs: [100, 111], completedPIDs: [111])
            #expect(manager.accessibilityPendingNewItems.isEmpty)
        }
    }

    @Test("Thaw 启动时已有项目及已保存分区的重启应用不被默认标记搬动")
    func startupAndSavedAssignmentsStayInPlace() throws {
        try withScratchDefaults { defaults in
            let existing = item("test.existing", pid: 120)
            let saved = item("test.saved", pid: 121)
            defaults.set([existing.uniqueIdentifier, saved.uniqueIdentifier], forKey: "macOS27SeenItems")
            defaults.set(["test.saved": "hidden"], forKey: "macOS27SectionAssignments")
            let manager = MenuBarItemManager()
            manager.registerAccessibilityNewItems(items: [existing], runningPIDs: [120], completedPIDs: [120])
            #expect(manager.accessibilityPendingNewItems.isEmpty)
            manager.registerAccessibilityNewItems(items: [existing, saved], runningPIDs: [120, 121], completedPIDs: [120, 121])
            #expect(manager.accessibilityPendingNewItems.isEmpty)
            #expect(manager.accessibilityAssignments["test.saved"] == "hidden")
        }
    }

    @Test("同应用新图标继承分区，扫描不会持久化临时自动化结果")
    func sharedApplicationAndTemporaryAssignments() throws {
        try withScratchDefaults { defaults in
            defaults.set([String](), forKey: "macOS27SeenItems")
            defaults.set(["test.existing": "visible"], forKey: "macOS27SectionAssignments")
            let manager = MenuBarItemManager()
            manager.accessibilityAssignments["test.existing"] = "hidden"
            manager.newItemsPlacement = .init(sectionKey: "visible", anchorIdentifier: "test.anchor:item", relation: .leftOfAnchor)
            let fresh = item("test.existing", pid: 105, title: "second")
            manager.registerAccessibilityNewItems(items: [fresh], runningPIDs: [105], completedPIDs: [105])
            #expect(manager.accessibilityPendingNewItems[fresh.uniqueIdentifier]?.sectionKey == "hidden")
            #expect(manager.accessibilityPendingNewItems[fresh.uniqueIdentifier]?.anchorIdentifier == nil)
            #expect((defaults.dictionary(forKey: "macOS27SectionAssignments") as? [String: String])?["test.existing"] == "visible")
        }
    }

    @Test("原本默认显示的应用新增图标时不会整组移入隐藏区域")
    func visibleApplicationKeepsSection() throws {
        try withScratchDefaults { _ in
            let manager = MenuBarItemManager()
            manager.registerAccessibilityNewItems(items: [item("test.visible", pid: 107)], runningPIDs: [107], completedPIDs: [107])
            manager.newItemsPlacement = .init(sectionKey: "hidden", anchorIdentifier: nil, relation: .sectionDefault)
            manager.registerAccessibilityNewItems(items: [item("test.visible", pid: 107, title: "second")], runningPIDs: [107], completedPIDs: [107])
            #expect(manager.accessibilityAssignments["test.visible"] == "visible")
        }
    }

    @Test("iStat 从通用 AX 标识变为模块标识不会再次自动定位")
    func identifierUpgradeDoesNotReorderExistingApplication() throws {
        try withScratchDefaults { defaults in
            let bundle = "com.bjango.istatmenus.status"
            let old = item(bundle, pid: 130, title: "Item-0")
            defaults.set([old.uniqueIdentifier], forKey: "macOS27SeenItems")
            defaults.set([bundle: "visible"], forKey: "macOS27SectionAssignments")
            let manager = MenuBarItemManager()
            manager.registerAccessibilityNewItems(items: [old], runningPIDs: [130], completedPIDs: [130])
            manager.accessibilityPendingNewItems[old.uniqueIdentifier] = .defaultValue
            let resolved = item(bundle, pid: 130, title: "com.bjango.istatmenus.combined")
            manager.registerAccessibilityNewItems(items: [resolved], runningPIDs: [130], completedPIDs: [130])
            #expect(manager.accessibilityPendingNewItems.isEmpty)
            #expect(manager.accessibilityAssignments[bundle] == "visible")
        }
    }

    @Test("新多图标应用和旧队列均不逐项自动排序，其他单图标应用仍正常定位")
    func multiItemApplicationPreservesInternalOrder() throws {
        try withScratchDefaults { defaults in
            defaults.set([String](), forKey: "macOS27SeenItems")
            let manager = MenuBarItemManager()
            let first = item("test.multi", pid: 131, title: "cpu")
            let second = item("test.multi", pid: 131, title: "network")
            let single = item("test.single", pid: 132)
            manager.registerAccessibilityNewItems(items: [first, second, single], runningPIDs: [131, 132], completedPIDs: [131, 132])
            #expect(manager.accessibilityPendingNewItems[first.uniqueIdentifier] == nil)
            #expect(manager.accessibilityPendingNewItems[second.uniqueIdentifier] == nil)
            #expect(manager.accessibilityPendingNewItems[single.uniqueIdentifier] != nil)
            manager.accessibilityPendingNewItems[first.uniqueIdentifier] = .defaultValue
            manager.discardAccessibilityMultiItemPlacements(items: [first, second, single])
            #expect(manager.accessibilityPendingNewItems[first.uniqueIdentifier] == nil)
            #expect(manager.accessibilityPendingNewItems[single.uniqueIdentifier] != nil)
        }
    }

    @Test("锚点左右方向及锚点消失后的默认边缘与标记一致")
    func anchorSelection() {
        let items = ["a", "b", "c"]
        let left = MenuBarItemManager.accessibilityNewItemAnchor(placement: .init(sectionKey: "visible", anchorIdentifier: "b", relation: .leftOfAnchor), identifiers: items, hiddenSectionStartsOnLeft: true)
        #expect(left?.identifier == "b" && left?.before == true)
        let right = MenuBarItemManager.accessibilityNewItemAnchor(placement: .init(sectionKey: "hidden", anchorIdentifier: "b", relation: .rightOfAnchor), identifiers: items, hiddenSectionStartsOnLeft: true)
        #expect(right?.identifier == "b" && right?.before == false)
        let fallback = MenuBarItemManager.accessibilityNewItemAnchor(placement: .init(sectionKey: "visible", anchorIdentifier: "gone", relation: .rightOfAnchor), identifiers: items, hiddenSectionStartsOnLeft: true)
        #expect(fallback?.identifier == "a" && fallback?.before == true)
        let hidden = MenuBarItemManager.accessibilityNewItemAnchor(placement: .init(sectionKey: "hidden", anchorIdentifier: nil, relation: .sectionDefault), identifiers: items, hiddenSectionStartsOnLeft: false)
        #expect(hidden?.identifier == "c" && hidden?.before == false)
        #expect(MenuBarItemManager.accessibilityNewItemAnchor(placement: .defaultValue, identifiers: [], hiddenSectionStartsOnLeft: true) == nil)
    }
}
