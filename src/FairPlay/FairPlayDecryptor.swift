import Foundation
import ZIPFoundation
import FairPlayCore

/// Progress of one decryption run, for the UI.
struct FairPlayProgress: Sendable {
    let phase: String
    let fraction: Double
    let detail: String
}

/// Collects the C core's per-attempt lines (size, mmap, errno, entropy) via a
/// per-call context pointer so concurrent callers cannot cross-talk logs.
private final class LogCallbackBox {
    let handler: (String) -> Void
    init(_ handler: @escaping (String) -> Void) { self.handler = handler }
}

private let coreLogTrampoline: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> Void = { ctx, message in
    guard let ctx, let message else { return }
    let box = Unmanaged<LogCallbackBox>.fromOpaque(ctx).takeUnretainedValue()
    box.handler(String(cString: message))
}

/// On-device FairPlay (App Store DRM) decryption of an IPA.
///
/// stage in an App Group container (fairplayd refuses data containers) →
/// unpack → place SC_Info beside every encrypted Mach-O → per slice
/// mmap(PROT_READ) + mremap_encrypted(cryptid 2) → check pages, entropy and
/// ARM64 landmarks → patch cryptid to 0 → repack → verify the packed IPA.
enum FairPlayDecryptor {

    struct Outcome: Sendable {
        let outputURL: URL
        let decrypted: Int
        let plain: Int
        let failed: Int
        let machO: Int
        let elapsed: TimeInterval
        let partial: Bool
        let verification: FairPlayVerification?
        /// Files whose kernel call succeeded, whose every page was read back and
        /// whose bytes changed, but which the plausibility rule still rejected.
        /// Zero once the entropy rule is active; non-zero means "the tool said no
        /// to something it actually decrypted", never "FairPlay refused".
        var heuristicRejected = 0
    }

    enum Failure: LocalizedError {
        case noStagingRoot
        case badArchive(String)
        case noPayload
        case alreadyPlain
        case notDecryptable(String)
        case packFailed(String)
        case notEnoughSpace(Int64, Int64)
        case cancelled
        case busy

        var errorDescription: String? {
            switch self {
            case .noStagingRoot:
                return S.Errors.noStaging
            case .badArchive(let detail):
                return S.Errors.badArchive(detail: detail)
            case .noPayload:
                return S.Errors.noPayload
            case .alreadyPlain:
                return S.Errors.alreadyPlain
            case .notDecryptable(let detail):
                return S.Errors.rejected(detail: detail)
            case .packFailed(let detail):
                return S.Errors.packFailed(detail: detail)
            case .notEnoughSpace(let free, let needed):
                return S.Errors.space(available: "\(free)", needed: "\(needed)")
            case .cancelled:
                return S.Errors.cancelled
            case .busy:
                return S.Errors.busy
            }
        }
    }

    private static let activeLock = NSLock()
    private static var activeDecryptCount = 0

    private static func tryAcquireActive() -> Bool {
        activeLock.lock()
        defer { activeLock.unlock() }
        guard activeDecryptCount == 0 else { return false }
        activeDecryptCount += 1
        return true
    }

    private static func releaseActive() {
        activeLock.lock()
        activeDecryptCount = max(0, activeDecryptCount - 1)
        activeLock.unlock()
    }

    /// Removes orphaned `fpwork-*` staging directories left behind by crashes.
    static func cleanupStaleStaging() {
        activeLock.lock()
        let busy = activeDecryptCount > 0
        activeLock.unlock()
        guard !busy else { return }

        let manager = FileManager.default
        let candidates = [FairPlayEnvironment.groupContainer(), FairPlayEnvironment.bundleStaging()].compactMap { $0 }
        for root in candidates {
            guard let items = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.lastPathComponent.hasPrefix("fpwork-") {
                try? manager.removeItem(at: item)
            }
        }
    }

    /// Staging root: App Group container first, bundle only when explicitly allowed.
    static func stagingRoot(allowBundle: Bool) -> URL? {
        if let group = FairPlayEnvironment.groupContainer() { return group }
        if allowBundle { return FairPlayEnvironment.bundleStaging() }
        return nil
    }

    /// Decrypts `ipaURL` and writes `<name>-decrypted.ipa` into Documents/Decrypted.
    /// Blocking; call from a background task.
    static func decrypt(
        ipaURL: URL,
        allowBundleStaging: Bool = false,
        isCancelled: () -> Bool = { false },
        report: (FairPlayProgress) -> Void = { _ in },
        log: @escaping (FairPlayLine) -> Void
    ) throws -> Outcome {
        guard tryAcquireActive() else {
            throw Failure.busy
        }
        defer { releaseActive() }

        guard let rawRoot = stagingRoot(allowBundle: allowBundleStaging) else {
            throw Failure.noStagingRoot
        }
        let root = rawRoot.resolvingSymlinksInPath()
        let manager = FileManager.default
        let started = Date()
        let stem = ipaURL.deletingPathExtension().lastPathComponent
        let work = root.appendingPathComponent("fpwork-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: work) }
        try manager.createDirectory(at: work, withIntermediateDirectories: true)

        let sourceSize = (try? manager.attributesOfItem(atPath: ipaURL.path)[.size] as? Int64) ?? 0
        let maxArchiveExpandedBytes: Int64 = 16 * 1024 * 1024 * 1024
        var declaredUncompressed: Int64 = 0
        let preflightArchive: Archive
        do {
            preflightArchive = try Archive(url: ipaURL, accessMode: .read, pathEncoding: nil)
        } catch {
            throw Failure.badArchive(error.localizedDescription)
        }
        for entry in preflightArchive {
            guard isSafeZipEntryPath(entry.path) else {
                throw Failure.badArchive(S.Errors.unsafePath)
            }
            if entry.type == .symlink {
                var targetData = Data()
                _ = try? preflightArchive.extract(entry, bufferSize: 4096, skipCRC32: true) { chunk in
                    if targetData.count + chunk.count <= 4096 { targetData.append(chunk) }
                }
                guard let targetPath = String(data: targetData, encoding: .utf8),
                      isSafeRelativeSymlinkTarget(targetPath, fromEntryPath: entry.path) else {
                    throw Failure.badArchive(S.Errors.unsafeSymlink)
                }
            }
            let entryBytes = Int64(clamping: entry.uncompressedSize)
            let (sum, overflow) = declaredUncompressed.addingReportingOverflow(entryBytes)
            if overflow || sum > maxArchiveExpandedBytes {
                throw Failure.badArchive(S.Errors.tooLarge)
            }
            declaredUncompressed = sum
        }
        if let capacity = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage {
            let headroom: Int64 = 256 * 1024 * 1024
            let estimateFromArchive = declaredUncompressed > 0
                ? declaredUncompressed.saturatingAdd(sourceSize).saturatingAdd(headroom)
                : sourceSize.saturatingMultiply(3)
            let needed = max(sourceSize.saturatingMultiply(3), estimateFromArchive)
            if capacity < needed {
                log(FairPlayLine(kind: .fail, text: S.Errors.logSpace(available: "\(capacity)", needed: "\(needed)")))
                throw Failure.notEnoughSpace(capacity, needed)
            }
        }

        // 1. unpack into the App Group container
        report(FairPlayProgress(phase: S.Run.unpack, fraction: 0, detail: ipaURL.lastPathComponent))
        log(FairPlayLine(kind: .phase, text: "UNPACK \(ipaURL.lastPathComponent) (\(sourceSize) B)"))
        do {
            try manager.unzipItem(at: ipaURL, to: work)
        } catch {
            throw Failure.badArchive(error.localizedDescription)
        }
        if isCancelled() { throw Failure.cancelled }

        let payloadRoot = work.appendingPathComponent("Payload", isDirectory: true)
        let payloadEntries = (try? manager.contentsOfDirectory(atPath: payloadRoot.path)) ?? []
        guard let bundleName = payloadEntries.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure.noPayload
        }
        let appDir = payloadRoot.appendingPathComponent(bundleName, isDirectory: true)
        log(FairPlayLine(kind: .info, text: "payload: \(bundleName)"))

        // 2. inventory + SINF placement
        report(FairPlayProgress(phase: S.Run.prepare, fraction: 0.04, detail: bundleName))
        let inventory = MachOScan.scanTree(appDir)
        var encryptedSlicesByPath: [String: Int] = [:]
        for row in inventory {
            let encrypted = row.slices.filter { $0.cryptid != 0 }
            guard let first = encrypted.first else { continue }
            encryptedSlicesByPath[row.path] = Int(first.cryptsize)
        }
        let replicated = replicateSinf(appDir: appDir, machos: inventory)
        log(FairPlayLine(kind: replicated > 0 ? .info : .warn,
                         text: "SINF placed beside \(replicated) nested binaries"))

        // 3. decrypt every encrypted Mach-O
        let encryptedFiles = inventory.filter { $0.slices.contains { $0.cryptid != 0 } }
        if encryptedFiles.isEmpty {
            log(FairPlayLine(kind: .info, text: "all \(inventory.count) Mach-O files are already plain (cryptid=0)"))
            throw Failure.alreadyPlain
        }
        log(FairPlayLine(kind: .phase,
                         text: "DECRYPT \(encryptedFiles.count) encrypted of \(inventory.count) Mach-O"))
        var decrypted = 0, plain = 0, failed = 0
        var heuristicRejected = 0
        var flagsCleared = 0
        var lastAttempt: String?
        var firstFailure: String?
        let total = max(encryptedFiles.count, 1)
        for (index, row) in encryptedFiles.enumerated() {
            if isCancelled() { throw Failure.cancelled }
            guard let url = safeChildURL(in: appDir, relative: row.path) else {
                failed += 1
                log(FairPlayLine(kind: .fail, text: "unsafe Mach-O path skipped: \(row.path)"))
                continue
            }
            report(FairPlayProgress(phase: S.Run.decrypting,
                                    fraction: 0.05 + 0.75 * Double(index) / Double(total),
                                    detail: S.Run.progressDetail(index: "\(index + 1)",
                                                                 total: "\(encryptedFiles.count)",
                                                                 path: row.path)))
            let scratch = url.appendingPathExtension("fpdec")
            try? manager.removeItem(at: scratch)
            var attemptLines: [String] = []
            let logBox = LogCallbackBox { line in
                attemptLines.append(line)
                log(FairPlayLine(kind: .info, text: line.trimmingCharacters(in: .whitespaces)))
            }
            var stats = fp_file_stats_t()
            let status: Int32 = withExtendedLifetime(logBox) {
                let ctx = Unmanaged.passUnretained(logBox).toOpaque()
                return url.path.withCString { input in
                    scratch.path.withCString { output in
                        fp_decrypt_file_ex(input, output, coreLogTrampoline, ctx, &stats)
                    }
                }
            }
            heuristicRejected += Int(stats.heuristic_rejected)
            flagsCleared += Int(stats.slices_plain)
            if isCancelled() {
                try? manager.removeItem(at: scratch)
                throw Failure.cancelled
            }
            lastAttempt = attemptLines.last
            switch status {
            case 0:
                var replaced = false
                do {
                    _ = try manager.replaceItemAt(url, withItemAt: scratch)
                    replaced = true
                } catch {
                    if (try? manager.removeItem(at: url)) != nil,
                       (try? manager.moveItem(at: scratch, to: url)) != nil {
                        replaced = true
                    }
                }
                if replaced {
                    // A file whose only "encryption" was a set flag had nothing to
                    // decrypt: report it as already plain, not as a decryption.
                    if stats.slices_ok == 0 && stats.slices_plain > 0 {
                        plain += 1
                        log(FairPlayLine(kind: .info, text: "flag cleared (cryptsize=0) \(row.path)"))
                    } else {
                        decrypted += 1
                        log(FairPlayLine(kind: .ok, text: "decrypted \(row.path)"))
                    }
                } else {
                    try? manager.removeItem(at: scratch)
                    failed += 1
                    log(FairPlayLine(kind: .fail, text: "replace failed \(row.path)"))
                }
            case 1:
                try? manager.removeItem(at: scratch)
                plain += 1
            default:
                try? manager.removeItem(at: scratch)
                failed += 1
                if firstFailure == nil { firstFailure = lastAttempt }
                let detail = lastAttempt.map { " — \($0)" } ?? ""
                log(FairPlayLine(kind: .fail, text: "FairPlay refused \(row.path)\(detail)"))
            }
        }
        plain += inventory.count - encryptedFiles.count
        if isCancelled() { throw Failure.cancelled }
        if flagsCleared > 0 {
            log(FairPlayLine(kind: .info,
                             text: "flags cleared on \(flagsCleared) slice(s) with cryptsize=0 (no plaintext to produce)"))
        }
        if heuristicRejected > 0 {
            // Never described as "FairPlay refused": the kernel did the work.
            log(FairPlayLine(kind: .warn,
                             text: "plausibility check rejected \(heuristicRejected) slice(s): mremap ok, "
                                 + "every page read back, bytes changed — see verdict new=/legacy= in the lines above"))
        }

        // 4. quick on-disk check before packing
        let after = MachOScan.scanTree(appDir)
        let stillEncrypted = after.flatMap(\.slices).filter { $0.cryptid != 0 }.count
        log(FairPlayLine(kind: stillEncrypted == 0 ? .ok : .fail,
                         text: "prepack: \(after.count) Mach-O, \(stillEncrypted) still encrypted"))

        guard decrypted > 0 else {
            throw Failure.notDecryptable(diagnose(firstFailure: firstFailure,
                                                 failed: failed, stillEncrypted: stillEncrypted))
        }
        if isCancelled() { throw Failure.cancelled }

        // 5. repack
        report(FairPlayProgress(phase: S.Run.repacking, fraction: 0.82, detail: "\(stem).ipa"))
        log(FairPlayLine(kind: .phase, text: "PACK"))
        let outDir = FairPlayEnvironment.documentsDirectory.appendingPathComponent("Decrypted", isDirectory: true)
        try? manager.createDirectory(at: outDir, withIntermediateDirectories: true)
        let partial = failed > 0 || stillEncrypted > 0
        let suffix = partial ? "-PARTIAL" : "-decrypted"
        let output = outDir.appendingPathComponent("\(stem)\(suffix).ipa")
        let temp = outDir.appendingPathComponent("\(stem)\(suffix).ipa.tmp")
        try? manager.removeItem(at: temp)
        do {
            try pack(directory: work, to: temp)
        } catch {
            try? manager.removeItem(at: temp)
            throw Failure.packFailed(error.localizedDescription)
        }
        if isCancelled() {
            try? manager.removeItem(at: temp)
            throw Failure.cancelled
        }
        try? manager.removeItem(at: output)
        do {
            try manager.moveItem(at: temp, to: output)
        } catch {
            try? manager.removeItem(at: temp)
            throw Failure.packFailed(error.localizedDescription)
        }
        let size = (try? manager.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        log(FairPlayLine(kind: .ok, text: "wrote \(output.lastPathComponent) (\(size) B)"))

        // 6. verify the artefact that is actually exported
        report(FairPlayProgress(phase: S.Run.verifying, fraction: 0.92, detail: S.Run.detailVerify))
        var verification: FairPlayVerification?
        do {
            let result = try FairPlayVerifier.verify(ipa: output, wasEncrypted: encryptedSlicesByPath)
            verification = result
            let entropyRange = result.files.filter(\.wasEncrypted).prefix(3)
                .map { String(format: "%.2f", $0.entropy) }.joined(separator: "/")
            log(FairPlayLine(kind: result.isClean ? .ok : .fail,
                             text: "verify: \(result.summary)" + (entropyRange.isEmpty ? "" : " · entropy \(entropyRange)")))
            for failure in result.failures.prefix(8) {
                log(FairPlayLine(kind: .fail, text: "verify failed: \(failure)"))
            }
        } catch {
            log(FairPlayLine(kind: .warn, text: "verify skipped: \(error.localizedDescription)"))
        }

        report(FairPlayProgress(phase: S.Run.done, fraction: 1, detail: output.lastPathComponent))
        return Outcome(outputURL: output, decrypted: decrypted, plain: plain, failed: failed,
                       machO: after.count, elapsed: Date().timeIntervalSince(started),
                       partial: partial || !(verification?.isClean ?? true), verification: verification,
                       heuristicRejected: heuristicRejected)
    }

    // MARK: - helpers

    /// Turns the C core's failure line into something the user can act on.
    ///
    /// Only the main path's errno (`…cid2…`) is allowed to produce a conclusion:
    /// the `READ|EXEC/cryptid1` fallback always fails with mmap EPERM on an
    /// unentitled process, and reading that as "no key for this account" is what
    /// used to send users on a pointless App Store detour.
    private static func diagnose(firstFailure: String?, failed: Int, stillEncrypted: Int) -> String {
        var text = S.Errors.diagnoseHead(failed: "\(failed)", remaining: "\(stillEncrypted)")
        guard let raw = firstFailure else { return text }
        let line = raw.trimmingCharacters(in: .whitespaces)
        let lower = line.lowercased()
        let mainPath = lower.contains("cid2") && !lower.contains("exec")
        if mainPath && (lower.contains("not permitted") || lower.contains("permission denied")) {
            // The most common cause by far, and the only one the user can fix:
            // the account that downloaded the app was never signed into the
            // system App Store on this device, so fairplayd holds no key.
            text = S.Errors.appleID
            return text
        }
        text += S.Errors.kernelTail(line: line)
        if mainPath, lower.contains("cannot allocate memory") {
            text += S.Errors.enomem
        } else if lower.contains("invalid argument") {
            text += S.Errors.invalidArgument
        }
        return text
    }

    /// Rejects Zip-Slip entry names (including multi-slash `//../` bypasses) before extraction
    /// so archive safety holds regardless of the linked ZIPFoundation minor version.
    static func isSafeZipEntryPath(_ rawPath: String) -> Bool {
        guard !rawPath.isEmpty,
              !rawPath.hasPrefix("/"),
              !rawPath.contains("\\"),
              !rawPath.contains("\0") else { return false }
        var normalized = rawPath
        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        if normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        guard !normalized.isEmpty else { return false }
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    static func isSafeRelativeSymlinkTarget(_ linkTarget: String, fromEntryPath entryPath: String) -> Bool {
        guard !linkTarget.isEmpty,
              !linkTarget.hasPrefix("/"),
              !linkTarget.contains("\\"),
              !linkTarget.contains("\0"),
              isSafeZipEntryPath(entryPath) else { return false }
        var depth = entryPath.split(separator: "/").dropLast().count
        var collapsed = linkTarget
        while collapsed.contains("//") {
            collapsed = collapsed.replacingOccurrences(of: "//", with: "/")
        }
        for part in collapsed.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." {
                if depth == 0 { return false }
                depth -= 1
            } else {
                depth += 1
            }
        }
        return true
    }

    /// Resolves `relative` strictly inside `root` while rejecting `..`, empty segments,
    /// and any symbolic link along the path chain.
    static func safeChildURL(in root: URL, relative: String) -> URL? {
        guard ArchivePath.isSafeArchivePath(relative) else { return nil }
        let manager = FileManager.default
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var current = canonicalRoot
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        for part in parts {
            current = current.appendingPathComponent(part)
            if let attrs = try? manager.attributesOfItem(atPath: current.path),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                return nil
            }
        }
        let resolvedParent = current.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard resolvedParent.path == canonicalRoot.path || resolvedParent.path.hasPrefix(rootPrefix) else {
            return nil
        }
        let candidatePath = resolvedParent.appendingPathComponent(current.lastPathComponent).standardizedFileURL.path
        guard candidatePath.hasPrefix(rootPrefix) else { return nil }
        return current
    }

    /// fairplayd resolves the license as `<dir>/SC_Info/<name>.sinf` next to the
    /// binary, so every encrypted Mach-O needs one. A store IPA ships a single
    /// SINF plus `SinfReplicationPaths`; installd would fan it out, here the
    /// replication is done explicitly and then checked against the real tree,
    /// because nested `PlugIns`/`Frameworks` paths often differ from the
    /// manifest's historical `Extensions/...` spelling.
    @discardableResult
    static func replicateSinf(appDir: URL, machos: [(path: String, slices: [MachOScan.SliceInfo])]) -> Int {
        let manager = FileManager.default
        guard let manifestURL = safeChildURL(in: appDir, relative: "SC_Info/Manifest.plist"),
              let data = try? Data(contentsOf: manifestURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let manifest = plist as? [String: Any],
              let sources = manifest["SinfPaths"] as? [String],
              let first = sources.first,
              let sourceURL = safeChildURL(in: appDir, relative: first) else { return 0 }
        let sourceValues = try? sourceURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard sourceValues?.isRegularFile == true, sourceValues?.isSymbolicLink != true else { return 0 }

        var copied = 0
        for relative in (manifest["SinfReplicationPaths"] as? [String] ?? []) {
            guard relative.lowercased().hasSuffix(".sinf"),
                  let destination = safeChildURL(in: appDir, relative: relative),
                  !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.createDirectory(at: destination.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            guard safeChildURL(in: appDir, relative: relative) != nil else { continue }
            if (try? manager.copyItem(at: sourceURL, to: destination)) != nil { copied += 1 }
        }

        for macho in machos where macho.slices.contains(where: { $0.cryptid != 0 }) {
            guard let binary = safeChildURL(in: appDir, relative: macho.path) else { continue }
            let name = binary.lastPathComponent
            let parentRelative = (macho.path as NSString).deletingLastPathComponent
            let sinfRelative = parentRelative.isEmpty
                ? "SC_Info/\(name).sinf"
                : "\(parentRelative)/SC_Info/\(name).sinf"
            guard let sinf = safeChildURL(in: appDir, relative: sinfRelative),
                  !manager.fileExists(atPath: sinf.path) else { continue }
            try? manager.createDirectory(at: sinf.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            guard safeChildURL(in: appDir, relative: sinfRelative) != nil else { continue }
            if (try? manager.copyItem(at: sourceURL, to: sinf)) != nil { copied += 1 }
        }
        return copied
    }

    private static func pack(directory: URL, to output: URL) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: output)
        let archive = try Archive(url: output, accessMode: .create)
        guard let walker = manager.enumerator(at: directory,
                                             includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                                             options: []) else {
            throw Failure.packFailed("cannot enumerate \(directory.lastPathComponent)")
        }
        let basePath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let basePrefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            guard values?.isDirectory != true else { continue }
            let itemPath = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard itemPath.hasPrefix(basePrefix) else { continue }
            let relative = String(itemPath.dropFirst(basePrefix.count))
            guard ArchivePath.isSafeArchivePath(relative) else { continue }
            try archive.addEntry(with: relative, fileURL: url, compressionMethod: .deflate)
        }
    }

    /// IPAs available in the app's Documents directory, newest first.
    static func candidateIPAs() -> [URL] {
        let manager = FileManager.default
        let documents = FairPlayEnvironment.documentsDirectory
        let entries = (try? manager.contentsOfDirectory(at: documents,
                                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                                        options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return l > r
            }
    }
}

private extension Int64 {
    func saturatingAdd(_ other: Int64) -> Int64 {
        let (result, overflow) = addingReportingOverflow(other)
        return overflow ? (other >= 0 ? .max : .min) : result
    }

    func saturatingMultiply(_ other: Int64) -> Int64 {
        let (result, overflow) = multipliedReportingOverflow(by: other)
        return overflow ? ((self >= 0) == (other >= 0) ? .max : .min) : result
    }
}
