//
//  MenuBarVisibility27.swift
//  Project: Thaw
//
//  Copyright (Thaw) © 2026 Toni Förster
//  Licensed under the GNU GPLv3

import AppKit

@objc private protocol MenuBarRestriction27: Sendable {
    @objc(activateWithConfiguration:completionHandler:)
    func activate(_ configuration: AnyObject, completion: @escaping (NSError?) -> Void)
    func invalidate()
}

/// 运行时检查新版菜单栏接口；不改写系统偏好，也不卸载系统菜单项。
final class MenuBarVisibility27 {
    private static let framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY)

    private var assertion: MenuBarRestriction27?
    private var pendingAssertion: MenuBarRestriction27?
    private var generation = 0
    private var allowed: Set<String>?
    private var pendingAllowed: Set<String>?
    private var completions: [@MainActor (Error?) -> Void] = []

    private func completePending(_ error: Error?) {
        pendingAllowed = nil
        let callbacks = completions
        completions.removeAll()
        for callback in callbacks {
            callback(error)
        }
    }

    private func cancelPending() {
        generation += 1
        pendingAssertion?.invalidate()
        pendingAssertion = nil
        completePending(NSError(
            domain: "Thaw.MenuBar27",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "菜单栏请求已被后续操作替代。请重试。"]
        ))
    }

    enum Failure: LocalizedError {
        case unavailable
        case configuration
        var errorDescription: String? {
            switch self {
            case .unavailable: "当前系统没有可用的菜单栏隐藏接口。"
            case .configuration: "无法创建菜单栏显示配置。"
            }
        }
    }

    static nonisolated func hiddenBundles(
        assignments: [String: String],
        expanded: Set<MenuBarSection.Name>,
        alwaysHiddenEnabled: Bool
    ) -> Set<String> {
        Set(assignments.compactMap { bundle, rawSection -> String? in
            guard !bundle.isEmpty, !bundle.hasPrefix("com.apple."), bundle != "com.stonerl.Thaw",
                  let section = MenuBarSection.Name(rawValue: rawSection), section != .visible
            else { return nil }
            let effective: MenuBarSection.Name = section == .alwaysHidden && !alwaysHiddenEnabled ? .hidden : section
            return expanded.contains(effective) ? nil : bundle
        })
    }

    /// 同一应用的其他项目仍被触发器控制时，不恢复整个应用的分区。
    static nonisolated func releasedBundles(previous: Set<String>, current: Set<String>) -> Set<String> {
        func bundles(_ identifiers: Set<String>) -> Set<String> {
            Set(identifiers.compactMap { identifier in
                guard let separator = identifier.firstIndex(of: ":"), separator != identifier.startIndex else { return nil }
                return String(identifier[..<separator])
            })
        }
        return bundles(previous).subtracting(bundles(current))
    }

    /// 旧配置按项目记录分区；同一应用存在冲突时采用更严格的隐藏分区。
    static nonisolated func profileAssignments(
        explicit: [String: String]?,
        itemSections: [String: String],
        pinnedHidden: Set<String>,
        pinnedAlwaysHidden: Set<String>
    ) -> [String: String] {
        let priority = ["visible": 0, "hidden": 1, "alwaysHidden": 2]
        var result = explicit ?? [:]
        if explicit == nil {
            for (identifier, section) in itemSections.sorted(by: { $0.key < $1.key }) {
                guard let separator = identifier.firstIndex(of: ":"), priority[section] != nil else { continue }
                let bundle = String(identifier[..<separator])
                if priority[section, default: 0] >= priority[result[bundle] ?? "visible", default: 0] {
                    result[bundle] = section
                }
            }
            for bundle in pinnedHidden where result[bundle] != "alwaysHidden" {
                result[bundle] = "hidden"
            }
            for bundle in pinnedAlwaysHidden {
                result[bundle] = "alwaysHidden"
            }
        }
        return result.filter { bundle, section in
            !bundle.isEmpty && !bundle.hasPrefix("com.apple.") && bundle != "com.stonerl.Thaw" && priority[section] != nil
        }
    }

    func release() {
        cancelPending()
        assertion?.invalidate()
        assertion = nil
        allowed = nil
    }

    func apply(hiddenBundles: Set<String>, completion: @escaping @MainActor (Error?) -> Void) {
        guard !hiddenBundles.isEmpty else {
            release()
            completion(nil)
            return
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let next = running.subtracting(hiddenBundles).union([Bundle.main.bundleIdentifier ?? "com.stonerl.Thaw"])
        guard allowed != next else {
            cancelPending()
            completion(nil)
            return
        }
        // 合并相同的后台刷新，不能每三秒取消一个尚在等待的四秒请求。
        if pendingAllowed == next {
            completions.append(completion)
            return
        }
        let initializer = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard Self.framework != nil,
              let assertionType = NSClassFromString("MBAssessmentModeAssertion") as? NSObject.Type,
              let configurationType = NSClassFromString("MBAssessmentModeConfiguration") as? NSObject.Type,
              assertionType.instancesRespond(to: #selector(MenuBarRestriction27.activate(_:completion:))),
              assertionType.instancesRespond(to: #selector(MenuBarRestriction27.invalidate)),
              configurationType.instancesRespond(to: initializer)
        else { completion(Failure.unavailable); return }
        guard let allocated = (configurationType as AnyObject).perform(NSSelectorFromString("alloc"))?.takeUnretainedValue(),
              let configuration = allocated.perform(
                  initializer,
                  with: (0 ..< 64).map(NSNumber.init(value:)) as NSArray,
                  with: Array(next) as NSArray
              )?.takeRetainedValue()
        else { completion(Failure.configuration); return }
        cancelPending()
        pendingAllowed = next
        completions = [completion]
        let request = generation
        let pending = unsafeBitCast(assertionType.init(), to: MenuBarRestriction27.self)
        pendingAssertion = pending
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self, self.generation == request else { return }
            self.generation += 1
            pending.invalidate()
            self.pendingAssertion = nil
            self.completePending(NSError(domain: "Thaw.MenuBar27", code: 1, userInfo: [NSLocalizedDescriptionKey: "菜单栏隐藏请求超时，未保存本次调整。"]))
        }
        pending.activate(configuration) { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == request else {
                    pending.invalidate()
                    return
                }
                self.generation += 1
                self.pendingAssertion = nil
                guard error == nil else {
                    pending.invalidate()
                    self.completePending(error)
                    return
                }
                self.assertion?.invalidate()
                self.assertion = pending
                self.allowed = next
                self.completePending(nil)
            }
        }
    }
}
