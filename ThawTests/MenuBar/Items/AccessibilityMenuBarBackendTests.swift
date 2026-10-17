//
//  AccessibilityMenuBarBackendTests.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit
import AXSwift6
import CoreGraphics
import Testing
@testable import Thaw

@Suite("macOS 27 辅助功能菜单栏")
struct AccessibilityMenuBarBackendTests {
    @Test("溢出项目和超宽旧分隔符不能作为可见菜单栏项目")
    func overflowFrames() {
        let strips = [CGRect(x: 0, y: 0, width: 2048, height: 30)]
        #expect(AccessibilityMenuBarBackend.isInMenuBar(CGRect(x: 1515, y: 3, width: 24, height: 24), strips: strips))
        #expect(!AccessibilityMenuBarBackend.isInMenuBar(CGRect(x: 7, y: 1155, width: 5002, height: 24), strips: strips))
        #expect(!AccessibilityMenuBarBackend.isInMenuBar(CGRect(x: 7, y: 1140, width: 24, height: 24), strips: strips))
        #expect(!AccessibilityMenuBarBackend.isInMenuBar(CGRect(x: -12, y: 3, width: 24, height: 24), strips: strips))
    }

    @Test("副屏使用自己的全局坐标，支持负坐标")
    func secondaryDisplay() {
        let strips = [CGRect(x: -1920, y: -1080, width: 1920, height: 30)]
        #expect(AccessibilityMenuBarBackend.isInMenuBar(CGRect(x: -50, y: -1077, width: 24, height: 24), strips: strips))
        #expect(!AccessibilityMenuBarBackend.isInMenuBar(CGRect(x: -50, y: 3, width: 24, height: 24), strips: strips))
    }

    @Test("无效的 AX 几何数据必须被过滤")
    func invalidFrames() {
        #expect(!AccessibilityMenuBarBackend.isValidFrame(.zero))
        #expect(!AccessibilityMenuBarBackend.isValidFrame(CGRect(x: CGFloat.infinity, y: 0, width: 24, height: 24)))
        #expect(!AccessibilityMenuBarBackend.isValidFrame(CGRect(x: 0, y: 0, width: -24, height: 24)))
    }

    @Test("空标题回退到标识或应用名，不同匿名项目可区分")
    func titles() {
        #expect(AccessibilityMenuBarBackend.displayTitle(appName: "测试应用", title: "项目", identifier: "id", index: 0) == "项目")
        #expect(AccessibilityMenuBarBackend.displayTitle(appName: "测试应用", title: " ", identifier: "id", index: 0) == "id")
        #expect(AccessibilityMenuBarBackend.displayTitle(appName: "测试应用", title: nil, identifier: nil, index: 1) == "测试应用 · 项目 2")
    }

    @Test("没有窗口编号的同名项目仍有独立的搜索标识和视图标识")
    func distinctAccessibilityItems() throws {
        let host = AccessibilityMenuBarBackend.Host(pid: 123, name: "测试", bundleID: "app.test")
        let element = UIElement(AXUIElementCreateApplication(123))
        let bounds = CGRect(x: 0, y: 0, width: 24, height: 24)
        let first = AccessibilityMenuBarBackend.Item(id: "123:0", host: host, title: "图标", identifier: "same", frame: bounds, element: element)
        let second = AccessibilityMenuBarBackend.Item(id: "123:1", host: host, title: "图标", identifier: "same", frame: bounds, element: element)
        var aliases = [String: String]()
        let tags = AccessibilityMenuBarBackend.resolveIdentities(items: [first, second], previous: [], aliases: &aliases)
        let firstTag = try #require(tags[first.id])
        let secondTag = try #require(tags[second.id])
        #expect(firstTag != secondTag)
        let firstItem = MenuBarItem(tag: firstTag, accessibilityItem: first, windowID: 0, ownerPID: 123,
                                   sourcePID: 123, bounds: bounds, title: nil, isOnScreen: true)
        let secondItem = MenuBarItem(tag: secondTag, accessibilityItem: second, windowID: 0, ownerPID: 123,
                                    sourcePID: 123, bounds: bounds, title: nil, isOnScreen: true)
        #expect(firstItem.presentationID != secondItem.presentationID)
    }
}
