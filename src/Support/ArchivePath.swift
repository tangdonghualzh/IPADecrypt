import Foundation

/// ZIP 条目路径的安全判断：拒绝 Zip-Slip、反斜杠与空段。
enum ArchivePath {

    static func isSafeArchivePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.contains("\\") && !path.contains("\0") && !parts.isEmpty &&
            parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}
