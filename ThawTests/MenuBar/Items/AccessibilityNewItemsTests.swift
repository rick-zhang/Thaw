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
