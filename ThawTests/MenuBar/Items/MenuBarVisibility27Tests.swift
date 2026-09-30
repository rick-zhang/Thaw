//
//  MenuBarVisibility27Tests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import Foundation
import Testing
@testable import Thaw

@Suite("macOS 27 区域隐藏策略")
struct MenuBarVisibility27Tests {
    private let assignments = ["app.visible": "visible", "app.hidden": "hidden", "app.always": "alwaysHidden"]

    @Test("收起时隐藏两个区域，展开普通隐藏区域不泄露永久隐藏项目")
    func independentSections() {
        #expect(MenuBarVisibility27.hiddenBundles(assignments: assignments, expanded: [], alwaysHiddenEnabled: true) == ["app.hidden", "app.always"])
        #expect(MenuBarVisibility27.hiddenBundles(assignments: assignments, expanded: [.hidden], alwaysHiddenEnabled: true) == ["app.always"])
        #expect(MenuBarVisibility27.hiddenBundles(assignments: assignments, expanded: [.hidden, .alwaysHidden], alwaysHiddenEnabled: true).isEmpty)
    }

    @Test("关闭永久隐藏区域后，其内容归入普通隐藏区域")
    func disabledAlwaysHidden() {
        #expect(MenuBarVisibility27.hiddenBundles(assignments: assignments, expanded: [.hidden], alwaysHiddenEnabled: false).isEmpty)
    }

    @Test("无效配置不能隐藏系统、Thaw 或没有身份的项目")
    func protectedItems() {
        let invalid = ["com.apple.MenuBarAgent": "hidden", "com.stonerl.Thaw": "hidden", "": "hidden", "app.unknown": "invalid"]
        #expect(MenuBarVisibility27.hiddenBundles(assignments: invalid, expanded: [], alwaysHiddenEnabled: true).isEmpty)
    }

    @Test("旧配置同应用的分区冲突使用更严格的隐藏级别")
    func legacyProfileMigration() {
        let result = MenuBarVisibility27.profileAssignments(
            explicit: nil,
            itemSections: ["app.one:first": "visible", "app.one:second": "alwaysHidden", "app.two:item": "hidden"],
            pinnedHidden: ["app.one", "app.three"], pinnedAlwaysHidden: []
        )
        #expect(result == ["app.one": "alwaysHidden", "app.two": "hidden", "app.three": "hidden"])
    }

    @Test("显式空配置清除旧分区，不回退到旧固定项目")
    func emptyNativeProfile() {
        #expect(MenuBarVisibility27.profileAssignments(
            explicit: [:], itemSections: ["app.one:item": "hidden"],
            pinnedHidden: ["app.one"], pinnedAlwaysHidden: []
        ).isEmpty)
    }

    @Test("配置迁移排除受保护应用和无效区域")
    func invalidProfileAssignments() {
        #expect(MenuBarVisibility27.profileAssignments(
            explicit: ["com.apple.controlcenter": "hidden", "com.stonerl.Thaw": "hidden", "app.one": "invalid", "app.two": "visible"],
            itemSections: [:], pinnedHidden: [], pinnedAlwaysHidden: []
        ) == ["app.two": "visible"])
    }

    @Test("新版分区可往返配置快照，旧快照无需新版字段")
    func profileRoundTrip() throws {
        let snapshot = MenuBarLayoutSnapshot(
            savedSectionOrder: [:], pinnedHiddenBundleIDs: [], pinnedAlwaysHiddenBundleIDs: [], customNames: [:],
            macOS27Assignments: ["app.one": "hidden"]
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(MenuBarLayoutSnapshot.self, from: data)
        #expect(decoded.macOS27Assignments == ["app.one": "hidden"])
        let legacy = Data(#"{"savedSectionOrder":{},"pinnedHiddenBundleIDs":[],"pinnedAlwaysHiddenBundleIDs":[],"customNames":{}}"#.utf8)
        #expect(try JSONDecoder().decode(MenuBarLayoutSnapshot.self, from: legacy).macOS27Assignments == nil)
    }

    @Test("同应用仍被其他触发器控制时不能提前恢复分区")
    func releasedTriggerBundles() {
        #expect(MenuBarVisibility27.releasedBundles(
            previous: ["app.one:first", "app.two:item"], current: ["app.one:second"]
        ) == ["app.two"])
    }
}
