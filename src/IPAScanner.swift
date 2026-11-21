import Foundation
import ZIPFoundation

/// 不真正解包，只读每个 Mach-O 的头部，判断这个 IPA 还需不需要解密。
enum IPAScanner {

    struct Info: Sendable, Equatable {
        var encrypted: Int
        var plain: Int
        var hasSINF: Bool
        var hasPayload: Bool

        var needsDecrypt: Bool { encrypted > 0 }
    }

    private struct Stop: Error {}

    private static func read(_ archive: Archive, _ entry: Entry, limit: Int) -> Data {
        var data = Data()
        _ = try? archive.extract(entry, bufferSize: 4 << 10, skipCRC32: true) { chunk in
            data.append(chunk)
            if data.count >= limit { throw Stop() }
        }
        return data
    }

    private static func isMachOMagic(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let raw = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return raw == 0xfeedfacf || raw == 0xbebafeca || raw == 0xbfbafeca
    }

    static func scan(_ url: URL) -> Info? {
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else {
            return nil
        }
        var encrypted = 0
        var plain = 0
        var hasSINF = false
        var hasPayload = false

        for entry in archive where entry.type == .file {
            if entry.path.hasPrefix("Payload/") { hasPayload = true }
            if entry.path.lowercased().hasSuffix(".sinf") { hasSINF = true }
            guard entry.path.hasPrefix("Payload/"),
                  entry.uncompressedSize >= 32,
                  entry.uncompressedSize <= 512 << 20 else { continue }

            // 先只看 4 KB 魔数：安装包里绝大多数是图片/资源，不必为它们解压 256 KB。
            let prefix = read(archive, entry, limit: 4 << 10)
            guard isMachOMagic(prefix) else { continue }
            let head = prefix.count >= 64 << 10 ? prefix : read(archive, entry, limit: 256 << 10)
            let slices = FairPlayVerifier.slices(head)
            guard !slices.isEmpty else { continue }
            if slices.contains(where: { $0.cryptid != 0 }) {
                encrypted += 1
            } else {
                plain += 1
            }
        }
        guard hasPayload else { return nil }
        return Info(encrypted: encrypted, plain: plain, hasSINF: hasSINF, hasPayload: hasPayload)
    }
}
