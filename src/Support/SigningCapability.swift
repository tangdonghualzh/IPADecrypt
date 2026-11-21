import Foundation

/// 这套签名实际能用哪个 App Group，进程内只解析一次。
///
/// FairPlay 只读取共享容器里的安装包，所以不含 `com.apple.security.application-groups`
/// 的重签（AltStore、免费个人团队）没有可暂存的位置——那是一种状态，不是某个 errno。
///
/// 来源顺序：
/// 1. Info.plist 的 `FairPlayAppGroup`（给自建签名留的显式覆盖项）；
/// 2. 内嵌描述文件里的 entitlements（重签后的真实答案，因此不绑定某一张证书）；
/// 3. 兜底候选（保证换了签名也能试一次）。
///
/// 每个候选都要通过一次真实可写探测：`containerURL` 非 nil 只是必要条件。
enum SigningCapability {

    struct Resolution: Equatable {
        let url: URL
        let identifier: String
    }

    enum State: Equatable {
        case available(Resolution)
        case unavailable

        var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }
    }

    /// 合并来源后的候选列表，尚未探测。
    static func groups() -> [String] {
        candidates
    }

    private static let candidates: [String] = {
        var values: [String] = []
        if let configured = Bundle.main.object(forInfoDictionaryKey: "FairPlayAppGroup") as? String,
           !configured.isEmpty {
            values.append(configured)
        }
        values.append(contentsOf: profileGroups)
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }()

    /// 签名时内嵌的描述文件授予的 App Group。
    static let profileGroups: [String] = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let raw = try? Data(contentsOf: url),
              let start = raw.range(of: Data("<?xml".utf8)),
              let end = raw.range(of: Data("</plist>".utf8), options: .backwards),
              start.lowerBound < end.upperBound,
              let plist = try? PropertyListSerialization.propertyList(
                from: raw.subdata(in: start.lowerBound..<end.upperBound), format: nil),
              let dictionary = plist as? [String: Any],
              let entitlements = dictionary["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else { return [] }
        return groups
    }()

    /// 进程内只解析一次：每次解密都去解析描述文件是浪费，运行时答案也不会变。
    static let state: State = {
        #if canImport(Darwin)
        let manager = FileManager.default
        for identifier in groups() {
            guard let container = manager.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
                continue
            }
            // 存在不等于可用：真建一个目录证明它有写权限。
            let probe = container.appendingPathComponent(".probe-\(UUID().uuidString)", isDirectory: true)
            do {
                try manager.createDirectory(at: probe, withIntermediateDirectories: false)
                try? manager.removeItem(at: probe)
            } catch {
                continue
            }
            return .available(Resolution(url: container, identifier: identifier))
        }
        #endif
        return .unavailable
    }()

    static var resolved: Resolution? {
        if case let .available(value) = state { return value }
        return nil
    }

    static var isMissingAppGroup: Bool {
        state == .unavailable
    }
}
