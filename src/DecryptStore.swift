import Foundation
import SwiftUI
import UIKit

struct IPAFile: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }

    var sizeText: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }

    var modifiedText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = S.Format.date
        return formatter.string(from: modified)
    }
}

enum RunPhase {
    case idle, running, success, partial, failed
}

struct DecryptResult: Identifiable {
    let id = UUID()
    let file: IPAFile
    let output: URL
    let decrypted: Int
    let plain: Int
    let machO: Int
    let failed: Int
    let elapsed: TimeInterval
    let partial: Bool
    let verification: FairPlayVerification?

    var sizeText: String {
        let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var isClean: Bool { !partial && (verification?.isClean ?? true) }
}

/// 界面唯一的数据源：列文件、跑解密、收集进度和日志。
@MainActor
final class DecryptStore: ObservableObject {

    @Published private(set) var phase: RunPhase = .idle
    @Published private(set) var step = ""
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double = 0
    @Published private(set) var logs: [String] = []
    @Published private(set) var result: DecryptResult?
    @Published private(set) var errorText: String?
    @Published private(set) var files: [IPAFile] = []
    @Published private(set) var outputs: [IPAFile] = []
    @Published private(set) var scan: [String: IPAScanner.Info] = [:]
    @Published private(set) var scanning: Set<String> = []
    @Published private(set) var activeFile: IPAFile?
    @Published private(set) var capability = CapabilityInfo()

    private var cancelFlag: CancelFlag?
    private var scanTask: Task<Void, Never>?

    struct CapabilityInfo {
        var groupID: String?
        var groupPath: String?
        var bundleWritable = false

        var isReady: Bool { groupID != nil || bundleWritable }
        var summary: String {
            if let groupID { return S.Env.capGroup(id: groupID) }
            if bundleWritable { return S.Env.capBundle }
            return S.Env.capNone
        }
        var note: String {
            if groupID != nil { return S.Env.noteGroup }
            if bundleWritable { return S.Env.noteBundle }
            return S.Env.noteNone }
    }

    init() {
        capability = Self.resolveCapability()
        refresh()
        FairPlayDecryptor.cleanupStaleStaging()
    }

    static func resolveCapability() -> CapabilityInfo {
        var info = CapabilityInfo()
        if let resolved = SigningCapability.resolved {
            info.groupID = resolved.identifier
            info.groupPath = resolved.url.path
        }
        info.bundleWritable = FairPlayEnvironment.isWritable(FairPlayEnvironment.bundleStaging())
        return info
    }

    var isRunning: Bool { phase == .running }
    var documents: URL { FairPlayEnvironment.documentsDirectory }
    var outputDirectory: URL { documents.appendingPathComponent("Decrypted", isDirectory: true) }
    private var isBundleStaging: Bool { SigningCapability.resolved == nil && capability.bundleWritable }

    // MARK: - 文件列表

    func refresh() {
        files = list(in: documents)
        outputs = list(in: outputDirectory)
        scheduleScan()
    }

    private func list(in directory: URL) -> [IPAFile] {
        let manager = FileManager.default
        let entries = (try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.pathExtension.lowercased() == "ipa" }
            .compactMap { url -> IPAFile? in
                guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]),
                      values.isRegularFile == true else { return nil }
                return IPAFile(url: url,
                               size: Int64(values.fileSize ?? 0),
                               modified: values.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.modified > $1.modified }
    }

    private func scheduleScan() {
        scanTask?.cancel()
        let targets = files
        scanTask = Task { [weak self] in
            for file in targets {
                guard let self, !Task.isCancelled else { return }
                if self.scan[file.id] != nil { continue }
                self.scanning.insert(file.id)
                let url = file.url
                let info = await Task.detached(priority: .utility) { IPAScanner.scan(url) }.value
                guard !Task.isCancelled else { return }
                self.scanning.remove(file.id)
                if let info { self.scan[file.id] = info }
            }
        }
    }

    // MARK: - 导入

    func importFile(_ url: URL, completion: ((String?) -> Void)? = nil) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
            var destination = documents.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let stem = url.deletingPathExtension().lastPathComponent
                let ext = url.pathExtension
                destination = documents.appendingPathComponent("\(stem)-\(Int(Date().timeIntervalSince1970)).\(ext)")
            }
            try FileManager.default.copyItem(at: url, to: destination)
            refresh()
            completion?(nil)
        } catch {
            completion?(error.localizedDescription)
        }
    }

    func handleOpenURL(_ url: URL) {
        guard url.pathExtension.lowercased() == "ipa" else { return }
        if url.deletingLastPathComponent().standardizedFileURL == documents.standardizedFileURL {
            refresh()
            return
        }
        importFile(url)
    }

    func delete(_ file: IPAFile) {
        try? FileManager.default.removeItem(at: file.url)
        if result?.output.standardizedFileURL == file.url.standardizedFileURL {
            result = nil
            if phase == .success || phase == .partial { phase = .idle }
        }
        refresh()
    }

    // MARK: - 解密

    func start(_ file: IPAFile) {
        guard !isRunning else { return }
        phase = .running
        result = nil
        errorText = nil
        logs = []
        step = S.Run.preparing
        detail = file.name
        fraction = 0
        activeFile = file

        let flag = CancelFlag()
        cancelFlag = flag
        let source = file.url
        let allowBundle = isBundleStaging

        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            do {
                let outcome = try FairPlayDecryptor.decrypt(
                    ipaURL: source,
                    allowBundleStaging: allowBundle,
                    isCancelled: { flag.isCancelled },
                    report: { progress in
                        DispatchQueue.main.async {
                            self.step = progress.phase
                            self.fraction = min(max(progress.fraction, 0), 1)
                            self.detail = progress.detail
                        }
                    },
                    log: { line in
                        DispatchQueue.main.async {
                            self.logs.append(line.rendered)
                            if self.logs.count > 600 {
                                self.logs.removeFirst(self.logs.count - 600)
                            }
                        }
                    }
                )
                DispatchQueue.main.async {
                    self.finish(file: file, outcome: outcome, started: started)
                }
            } catch {
                DispatchQueue.main.async {
                    self.fail(error)
                }
            }
        }
    }

    func cancel() {
        cancelFlag?.cancel()
    }

    private func finish(file: IPAFile, outcome: FairPlayDecryptor.Outcome, started: Date) {
        let partial = outcome.partial || !(outcome.verification?.isClean ?? true)
        phase = partial ? .partial : .success
        fraction = 1
        step = partial ? S.Run.finishedPartial : S.Run.finished
        detail = outcome.outputURL.lastPathComponent
        result = DecryptResult(file: file,
                               output: outcome.outputURL,
                               decrypted: outcome.decrypted,
                               plain: outcome.plain,
                               machO: outcome.machO,
                               failed: outcome.failed,
                               elapsed: outcome.elapsed,
                               partial: partial,
                               verification: outcome.verification)
        activeFile = nil
        refresh()
    }

    private func fail(_ error: Error) {
        let failure = error as? FairPlayDecryptor.Failure
        if case .cancelled = failure {
            phase = .idle
            step = S.Run.cancelled
        } else {
            phase = .failed
            step = S.Run.failed
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if case .noStagingRoot = failure {
                errorText = S.Errors.noStagingLong
            }
        }
        activeFile = nil
        refresh()
    }

    func clearResult() {
        phase = .idle
        result = nil
        errorText = nil
        logs = []
        step = ""
        detail = ""
        fraction = 0
    }

    // MARK: - 环境诊断

    var environmentLines: [String] {
        var lines: [String] = []
        lines.append(S.Env.system(version: FairPlayEnvironment.systemVersion,
                                  model: FairPlayEnvironment.deviceModel()))
        lines.append(FairPlayEnvironment.mremapSymbolResolved ? S.Env.mremapDyld : S.Env.mremapSyscall)
        if let id = capability.groupID, let path = capability.groupPath {
            lines.append(S.Env.capGroup(id: id))
            lines.append(S.Env.container(path: path))
            lines.append(S.Env.writable(value: FairPlayEnvironment.isWritable(URL(fileURLWithPath: path)) ? S.Env.yes : S.Env.no))
        } else {
            lines.append(S.Env.groupMissing)
            lines.append(S.Env.bundleWritable(value: capability.bundleWritable ? S.Env.yes : S.Env.no))
        }
        lines.append(S.Env.dataContainer(path: NSHomeDirectory()))
        lines.append(S.Env.documentsWritable(value: FairPlayEnvironment.isWritable(documents) ? S.Env.yes : S.Env.no))
        return lines
    }
}
