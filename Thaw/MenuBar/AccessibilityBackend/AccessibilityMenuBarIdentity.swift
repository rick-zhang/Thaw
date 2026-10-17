import Foundation

extension AccessibilityMenuBarBackend {
    /// 对同一 AX 元素补全稳定身份，保留已经被设置引用的内部 tag。
    /// 枚举序号、标题和坐标均不作为跨扫描身份的证据。
    nonisolated static func resolveIdentities(
        items: [Item], previous: [MenuBarItem], aliases: inout [String: String], unverifiedBundles: Set<String> = []
    ) -> [String: MenuBarItemTag] {
        func stableKey(_ item: Item) -> String? {
            guard let bundle = item.host.bundleID, !bundle.isEmpty,
                  let identifier = item.identifier, !identifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return MenuBarItemTag(namespace: .string(bundle), title: identifier).persistenceKey
        }
        let counts = Dictionary(grouping: items.compactMap(stableKey), by: { $0 }).mapValues(\.count)
        var result = [String: MenuBarItemTag]()
        var used = Set<String>()
        for item in items {
            let namespace = item.host.bundleID ?? "pid-\(item.host.pid)"
            let key = stableKey(item)
            let uniqueKey = key.flatMap { counts[$0] == 1 && !unverifiedBundles.contains(namespace) ? $0 : nil }
            let matches = previous.filter { old in
                guard let ax = old.accessibilityItem else { return false }
                return ax.host.pid == item.host.pid && ax.host.bundleID == item.host.bundleID && ax.element == item.element
            }
            // 双向唯一才接受；同一个 AX 元素被重复枚举也不能合并两个项目。
            let uniqueElement = items.filter {
                $0.host.pid == item.host.pid && $0.element == item.element
            }.count == 1
            var tag: MenuBarItemTag?
            if matches.count == 1, uniqueElement, let old = matches.first, let oldAX = old.accessibilityItem {
                let oldKey = stableKey(oldAX)
                let compatible = key == nil || oldKey == nil || oldKey == key
                let conflictingAlias = uniqueKey.map { newKey in
                    aliases.contains { $0.key != newKey && $0.value == old.tag.persistenceKey }
                        || aliases[newKey].map { $0 != old.tag.persistenceKey } == true
                } ?? false
                if compatible && !conflictingAlias { tag = old.tag }
            }
            if tag == nil, let uniqueKey,
               let encoded = aliases[uniqueKey], let stored = MenuBarItemTag(persistenceKey: encoded),
               stored.namespace == .string(namespace), !stored.title.isEmpty,
               aliases.values.filter({ $0 == encoded }).count == 1 {
                tag = stored
            }
            if tag == nil, let uniqueKey { tag = MenuBarItemTag(persistenceKey: uniqueKey) }
            if tag == nil || used.contains(tag!.persistenceKey) {
                // UUID 只承担内部身份，不作为用户看到的名称；匿名项目跨进程不猜测关联。
                tag = MenuBarItemTag(namespace: .string(namespace), title: "temporary-\(UUID().uuidString)")
            }
            guard let resolved = tag else { continue }
            used.insert(resolved.persistenceKey)
            result[item.id] = resolved
            if let uniqueKey, aliases[uniqueKey] == nil {
                // 不让不同稳定标识指向同一个内部身份。
                if !aliases.contains(where: { $0.key != uniqueKey && $0.value == resolved.persistenceKey }) {
                    aliases[uniqueKey] = resolved.persistenceKey
                }
            }
        }
        return result
    }
}
