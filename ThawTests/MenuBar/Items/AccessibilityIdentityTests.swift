import AppKit
import AXSwift6
import Testing
@testable import Thaw

@MainActor
struct AccessibilityIdentityTests {
    private func ax(_ id: String, _ identifier: String?, pid: pid_t = 100, element: UIElement) -> AccessibilityMenuBarBackend.Item {
        .init(id: id, host: .init(pid: pid, name: "测试", bundleID: "test.identity"), title: "动态图标", identifier: identifier,
              frame: CGRect(x: 100, y: 0, width: 24, height: 24), element: element)
    }

    private func managed(_ item: AccessibilityMenuBarBackend.Item, _ tag: MenuBarItemTag) -> MenuBarItem {
        .init(tag: tag, accessibilityItem: item, windowID: 0, ownerPID: item.host.pid, sourcePID: item.host.pid,
              bounds: item.frame, title: item.title, isOnScreen: true)
    }

    @Test("临时标识升级保留设置、锚点与待办引用，稳定别名可跨重启恢复")
    func promotionAndRelaunch() throws {
        try withScratchDefaults { defaults in
            let element = UIElement(AXUIElementCreateApplication(100))
            let anonymous = ax("100:0", nil, element: element)
            var aliases = [String: String]()
            let original = try #require(AccessibilityMenuBarBackend.resolveIdentities(items: [anonymous], previous: [], aliases: &aliases)[anonymous.id])
            #expect(original.title.hasPrefix("temporary-"))
            let old = managed(anonymous, original)
            Defaults.set([old.uniqueIdentifier: "处理器"], forKey: .menuBarItemCustomNames)
            let manager = MenuBarItemManager()
            manager.newItemsPlacement = .init(sectionKey: "visible", anchorIdentifier: old.uniqueIdentifier, relation: .leftOfAnchor)
            manager.accessibilityPendingNewItems[old.uniqueIdentifier] = .defaultValue
            let stable = ax("100:4", "cpu", element: element)
            let promoted = try #require(AccessibilityMenuBarBackend.resolveIdentities(items: [stable], previous: [old], aliases: &aliases)[stable.id])
            let current = managed(stable, promoted)
            #expect(current.uniqueIdentifier == old.uniqueIdentifier)
            #expect(current.presentationID == old.presentationID)
            #expect(current.customName == "处理器")
            #expect(manager.newItemsPlacement.anchorIdentifier == current.uniqueIdentifier)
            #expect(manager.accessibilityPendingNewItems[current.uniqueIdentifier] != nil)
            defaults.set(aliases, forKey: "macOS27IdentityAliases")
            let restarted = MenuBarItemManager()
            let newProcess = ax("101:0", "cpu", pid: 101, element: UIElement(AXUIElementCreateApplication(101)))
            let restored = AccessibilityMenuBarBackend.resolveIdentities(items: [newProcess], previous: [], aliases: &restarted.accessibilityIdentityAliases)
            #expect(restored[newProcess.id] == original)
        }
    }

    @Test("匿名图标换枚举顺序仍按 AX 元素关联，不按序号或位置互换")
    func reorderedAnonymousElements() throws {
        let a = UIElement(AXUIElementCreateApplication(201))
        let b = UIElement(AXUIElementCreateApplication(202))
        let first = ax("100:0", nil, element: a)
        let second = ax("100:1", nil, element: b)
        var aliases = [String: String]()
        let initial = AccessibilityMenuBarBackend.resolveIdentities(items: [first, second], previous: [], aliases: &aliases)
        let previous = [managed(first, try #require(initial[first.id])), managed(second, try #require(initial[second.id]))]
        let swappedA = ax("100:1", "cpu", element: a)
        let swappedB = ax("100:0", "network", element: b)
        let resolved = AccessibilityMenuBarBackend.resolveIdentities(items: [swappedB, swappedA], previous: previous, aliases: &aliases)
        #expect(resolved[swappedA.id] == initial[first.id])
        #expect(resolved[swappedB.id] == initial[second.id])
    }

    @Test("重复稳定标识及不同进程的匿名图标不能猜测跨重启身份")
    func ambiguousAndRestartedItems() throws {
        let a = ax("100:0", "duplicate", element: UIElement(AXUIElementCreateApplication(201)))
        let b = ax("100:1", "duplicate", element: UIElement(AXUIElementCreateApplication(202)))
        var aliases = [String: String]()
        let tags = AccessibilityMenuBarBackend.resolveIdentities(items: [a, b], previous: [], aliases: &aliases)
        #expect(tags[a.id] != tags[b.id])
        #expect(aliases.isEmpty)
        let newProcess = ax("101:0", nil, pid: 101, element: a.element)
        let next = AccessibilityMenuBarBackend.resolveIdentities(items: [newProcess], previous: [managed(a, try #require(tags[a.id]))], aliases: &aliases)
        #expect(next[newProcess.id] != tags[a.id])
    }

    @Test("已确认的标识短暂消失保留身份，换成另一稳定标识不合并")
    func missingOrChangedIdentifier() throws {
        let element = UIElement(AXUIElementCreateApplication(100))
        let stable = ax("100:0", "cpu", element: element)
        var aliases = [String: String]()
        let tag = try #require(AccessibilityMenuBarBackend.resolveIdentities(items: [stable], previous: [], aliases: &aliases)[stable.id])
        let missing = ax("100:1", nil, element: element)
        let retained = try #require(AccessibilityMenuBarBackend.resolveIdentities(items: [missing], previous: [managed(stable, tag)], aliases: &aliases)[missing.id])
        #expect(retained == tag)
        let other = ax("100:1", "network", element: element)
        let changed = AccessibilityMenuBarBackend.resolveIdentities(items: [other], previous: [managed(missing, retained)], aliases: &aliases)
        #expect(changed[other.id] != tag)
    }
    @Test("有现场 AX 证据的旧 Item-0 可关联，但复用序号不能冒领身份")
    func legacyTagRequiresElementEvidence() throws {
        let element = UIElement(AXUIElementCreateApplication(100))
        let oldAX = ax("100:0", nil, element: element)
        let legacy = MenuBarItemTag(namespace: .string("test.identity"), title: "Item-0")
        let previous = managed(oldAX, legacy)
        var aliases = [String: String]()
        let replacement = ax("100:0", nil, element: UIElement(AXUIElementCreateApplication(202)))
        let unknown = AccessibilityMenuBarBackend.resolveIdentities(items: [replacement], previous: [previous], aliases: &aliases)
        #expect(unknown[replacement.id] != legacy)
        let stable = ax("100:4", "cpu", element: element)
        let known = AccessibilityMenuBarBackend.resolveIdentities(items: [stable], previous: [previous], aliases: &aliases)
        #expect(known[stable.id] == legacy)
    }

    @Test("损坏或跨应用的别名不能覆盖当前项目身份")
    func rejectsInvalidAliases() throws {
        let stable = ax("100:0", "cpu", element: UIElement(AXUIElementCreateApplication(100)))
        let key = MenuBarItemTag(namespace: .string("test.identity"), title: "cpu").persistenceKey
        let foreign = MenuBarItemTag(namespace: .string("another.app"), title: "temporary-old")
        var aliases = [key: foreign.persistenceKey]
        let result = AccessibilityMenuBarBackend.resolveIdentities(items: [stable], previous: [], aliases: &aliases)
        #expect(result[stable.id]?.namespace == .string("test.identity"))
        #expect(result[stable.id] != foreign)
    }

    @Test("不完整扫描不能证明标识唯一，完成扫描后才能建立别名")
    func partialScanDefersAssociation() throws {
        let stable = ax("100:0", "cpu", element: UIElement(AXUIElementCreateApplication(100)))
        var aliases = [String: String]()
        let partial = try #require(AccessibilityMenuBarBackend.resolveIdentities(
            items: [stable], previous: [], aliases: &aliases, unverifiedBundles: ["test.identity"]
        )[stable.id])
        #expect(aliases.isEmpty)
        let complete = AccessibilityMenuBarBackend.resolveIdentities(items: [stable], previous: [managed(stable, partial)], aliases: &aliases)
        #expect(complete[stable.id] == partial)
        #expect(aliases.count == 1)
    }

}
