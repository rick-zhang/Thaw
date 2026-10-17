import AppKit
import CoreGraphics
import AXSwift6
import Testing
@testable import Thaw

struct AccessibilityOrderTests {
    @Test("单项排序只移动用户选中项，并保留其他成员顺序")
    func singleMovePlan() {
        let left = MenuBarItemManager.accessibilitySingleMoveDestination(current: ["a", "b", "c", "d"], desired: ["c", "a", "b", "d"], moving: "c")
        #expect(left?.anchor == "a")
        #expect(left?.before == true)
        let right = MenuBarItemManager.accessibilitySingleMoveDestination(current: ["a", "b", "c", "d"], desired: ["a", "c", "d", "b"], moving: "b")
        #expect(right?.anchor == "d")
        #expect(right?.before == false)
        #expect(MenuBarItemManager.accessibilitySingleMoveDestination(current: ["a", "b", "c"], desired: ["c", "b", "a"], moving: "b") == nil)
        #expect(MenuBarItemManager.accessibilitySingleMoveDestination(current: ["a", "b"], desired: ["a", "a"], moving: "a") == nil)
        #expect(MenuBarItemManager.accessibilitySingleMoveDestination(current: ["a", "b"], desired: ["a", "c"], moving: "a") == nil)
    }

    @Test("隐藏区边界使用完整图标宽度，并拒绝跨屏坐标")
    func concealedItemsMustBeEntirelyToTheLeft() {
        let visible = CGRect(x: 200, y: -900, width: 24, height: 30)
        #expect(MenuBarItemManager.accessibilityHiddenItemPrecedesVisible(CGRect(x: 140, y: -900, width: 60, height: 30), visible))
        #expect(!MenuBarItemManager.accessibilityHiddenItemPrecedesVisible(CGRect(x: 180, y: -900, width: 60, height: 30), visible))
        #expect(!MenuBarItemManager.accessibilityHiddenItemPrecedesVisible(CGRect(x: 240, y: -900, width: 24, height: 30), visible))
        #expect(!MenuBarItemManager.accessibilityHiddenItemPrecedesVisible(CGRect(x: 140, y: 0, width: 24, height: 30), visible))
        #expect(!MenuBarItemManager.accessibilityHiddenItemPrecedesVisible(.zero, visible))
    }

    @MainActor
    @Test("新版分区必须读取隔离存储，不能绕过 Defaults")
    func readsIsolatedAssignments() throws {
        try withScratchDefaults { defaults in
            let assignments = ["test.application": "hidden"]
            defaults.set(assignments, forKey: "macOS27SectionAssignments")
            #expect(MenuBarItemManager().accessibilityAssignments == assignments)
        }
    }

    @Test func usesHostPositionInsteadOfStaleApplicationPosition() {
        let host = AccessibilityMenuBarBackend.Host(pid: 123, name: "测试应用")
        let stale = CGRect(x: 100, y: 3, width: 24, height: 24)
        let live = CGRect(x: 700, y: 0, width: 38, height: 30)
        let item = AccessibilityMenuBarBackend.Item(id: "123:0", host: host, title: "图标", frame: stale,
                                                    element: UIElement(AXUIElementCreateApplication(123)))
        let slot = AccessibilityMenuBarBackend.HostedSlot(pid: 123, identifier: nil, frame: live)
        #expect(AccessibilityMenuBarBackend.matchFrames(items: [item], slots: [slot])[item.id] == live)
        #expect(AccessibilityMenuBarBackend.matchFrames(items: [item], slots: []).isEmpty)
        let other = AccessibilityMenuBarBackend.Item(id: "123:1", host: host, title: "图标", frame: stale,
                                                     element: item.element)
        #expect(AccessibilityMenuBarBackend.matchFrames(items: [item, other], slots: [slot, slot]).isEmpty)
    }

    @Test("配置排序忽略已退出项目、去重，并保留新项目的相对顺序")
    func profileOrderReconcilesLiveItems() {
        #expect(MenuBarItemManager.accessibilityProfileOrder(
            saved: ["b", "closed", "a", "b"], current: ["new1", "a", "new2", "b"]
        ) == ["b", "a", "new1", "new2"])
        #expect(MenuBarItemManager.accessibilityProfileOrder(saved: [], current: ["b", "a"]) == ["b", "a"])
        #expect(MenuBarItemManager.accessibilityProfileOrder(saved: ["a"], current: []) == [])
    }

    @Test("重置覆盖已退出应用，但排除系统项目和 Thaw 自身")
    func resetAssignmentsIncludesClosedApplications() {
        #expect(MenuBarItemManager.accessibilityResetAssignments(
            existing: ["closed.app": "hidden", "open.app": "alwaysHidden", "com.apple.controlcenter": "hidden", "thaw.test": "hidden"],
            section: .visible, ownBundle: "thaw.test"
        ) == ["closed.app": "visible", "open.app": "visible"])
    }

    @Test func validatesActualAdjacency() {
        let anchor = CGRect(x: 100, y: -900, width: 24, height: 24)
        let item = CGRect(x: 128, y: -900, width: 24, height: 24)
        #expect(MenuBarItemManager.accessibilityOrderIsAdjacent(frames: ["a": anchor, "b": item], item: "b", after: "a"))
        #expect(!MenuBarItemManager.accessibilityOrderIsAdjacent(frames: ["a": anchor, "b": item], item: "a", after: "b"))
    }

    @Test func rejectsInterveningAndOtherDisplayItems() {
        let anchor = CGRect(x: 100, y: 3, width: 24, height: 24)
        let item = CGRect(x: 160, y: 3, width: 24, height: 24)
        let intervening = CGRect(x: 130, y: 3, width: 24, height: 24)
        #expect(!MenuBarItemManager.accessibilityOrderIsAdjacent(frames: ["a": anchor, "b": item, "c": intervening], item: "b", after: "a"))
        #expect(!MenuBarItemManager.accessibilityOrderIsAdjacent(frames: ["a": anchor, "b": item.offsetBy(dx: 0, dy: 1080)], item: "b", after: "a"))
        #expect(!MenuBarItemManager.accessibilityOrderIsAdjacent(frames: ["a": anchor], item: "b", after: "a"))
    }
}
