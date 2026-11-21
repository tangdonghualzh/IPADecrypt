import SwiftUI
import UniformTypeIdentifiers

@main
struct IPADecryptApp: App {
    @StateObject private var store = DecryptStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onOpenURL { store.handleOpenURL($0) }
        }
    }
}

private enum Palette {
    static let accent = Color(red: 0.10, green: 0.58, blue: 0.55)
    static let accentDeep = Color(red: 0.05, green: 0.36, blue: 0.38)
    static let warn = Color(red: 0.85, green: 0.48, blue: 0.10)
    static let danger = Color(red: 0.78, green: 0.20, blue: 0.20)
    static let ok = Color(red: 0.16, green: 0.60, blue: 0.34)
}

private let ipaType = UTType("com.apple.itunes.ipa") ?? UTType(filenameExtension: "ipa") ?? .zip

struct ContentView: View {
    @EnvironmentObject private var store: DecryptStore
    @State private var showImporter = false
    @State private var showInfo = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    HeroCard()
                    if store.phase == .running {
                        RunningCard()
                    } else {
                        ImportCard(showImporter: $showImporter)
                        FilesCard(showImporter: $showImporter)
                        if store.phase == .failed, let error = store.errorText {
                            FailureCard(message: error)
                        }
                        if let result = store.result {
                            ResultCard(result: result)
                        }
                    }
                    OutputsCard()
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .background(backdrop)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(S.App.refresh)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel(S.App.info)
                }
            }
        }
        .tint(Palette.accent)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [ipaType, .zip],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                store.importFile(url) { error in
                    if let error { importError = error }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert(S.Home.alertTitle, isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button(S.Home.alertOK, role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .sheet(isPresented: $showInfo) {
            InfoSheet()
                .environmentObject(store)
        }
    }

    private var backdrop: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground)
            LinearGradient(colors: [Palette.accent.opacity(0.16), .clear],
                           startPoint: .top, endPoint: .center)
                .frame(maxHeight: 320, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
        }
    }
}

// MARK: - 顶部

private struct HeroCard: View {
    @EnvironmentObject private var store: DecryptStore

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(LinearGradient(colors: [Palette.accent, Palette.accentDeep],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 54, height: 54)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "lock.open.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Palette.ok))
                            .offset(x: 9, y: 9)
                    }
            }
            Text(S.App.title)
                .font(.title2.weight(.bold))
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Circle()
                    .fill(store.capability.isReady ? Palette.ok : Palette.warn)
                    .frame(width: 7, height: 7)
                Text(store.capability.isReady ? S.App.ready : S.App.restricted)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
        }
    }
}

// MARK: - 导入

private struct ImportCard: View {
    @Binding var showImporter: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button {
                showImporter = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 20, weight: .semibold))
                    Text(S.Home.pick).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").font(.footnote).opacity(0.7)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(colors: [Palette.accent, Palette.accentDeep],
                                   startPoint: .leading, endPoint: .trailing),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 待解密列表

private struct FilesCard: View {
    @EnvironmentObject private var store: DecryptStore
    @Binding var showImporter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: S.Home.documents, badge: S.Home.filesBadge(count: "\(store.files.count)"))
            if store.files.isEmpty {
                EmptyRow(text: S.Home.empty,
                         actionTitle: S.Home.importAction) { showImporter = true }
            } else {
                VStack(spacing: 0) {
                    ForEach(store.files) { file in
                        FileRow(file: file)
                        if file.id != store.files.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }
}

private struct FileRow: View {
    @EnvironmentObject private var store: DecryptStore
    let file: IPAFile

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color(uiColor: .tertiarySystemFill))
                    .frame(width: 34, height: 34)
                Image(systemName: "doc.zipper")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Palette.accentDeep)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(file.sizeText)
                    Text("·")
                    Text(file.modifiedText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            StatusChip(file: file)
            Button {
                store.start(file)
            } label: {
                Text(S.Home.decrypt)
                    .font(.caption.weight(.bold))
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(Palette.accent))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                store.delete(file)
            } label: {
                Label(S.Home.delete, systemImage: "trash")
            }
        }
    }
}

private struct StatusChip: View {
    @EnvironmentObject private var store: DecryptStore
    let file: IPAFile

    var body: some View {
        Group {
            if store.scanning.contains(file.id) {
                chip(text: S.Status.scanning, color: .secondary)
            } else if let info = store.scan[file.id] {
                if info.encrypted > 0 {
                    if info.hasSINF {
                        chip(text: S.Status.encrypted(count: "\(info.encrypted)"), color: Palette.ok)
                    } else {
                        chip(text: S.Status.missingSinf, color: Palette.warn)
                    }
                } else {
                    chip(text: S.Status.plain, color: .secondary)
                }
            } else {
                chip(text: S.Status.ipa, color: .secondary)
            }
        }
    }

    private func chip(text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

// MARK: - 运行中

private struct RunningCard: View {
    @EnvironmentObject private var store: DecryptStore
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.large)
                    .tint(Palette.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.step)
                        .font(.headline)
                    Text(store.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(S.Run.progressPercent(value: "\(Int(store.fraction * 100))"))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(Palette.accentDeep)
            }
            ProgressView(value: store.fraction)
                .tint(Palette.accent)
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    store.cancel()
                } label: {
                    Label(S.Run.cancel, systemImage: "stop.circle")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                Spacer()
                Button {
                    showLog.toggle()
                } label: {
                    Label(showLog ? S.Run.hideLog : S.Run.showLog, systemImage: "text.alignleft")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
            }
            if showLog {
                LogView(lines: store.logs)
            }
        }
        .cardStyle()
    }
}

private struct LogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
            }
            .frame(height: 190)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onChange(of: lines.count) { count in
                guard count > 0 else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("[FAIL]") { return Palette.danger }
        if line.hasPrefix("[OK]") { return Palette.ok }
        if line.hasPrefix("[PHASE]") { return Palette.accentDeep }
        if line.hasPrefix("[WARN]") { return Palette.warn }
        return .secondary
    }
}

// MARK: - 结果

private struct ResultCard: View {
    @EnvironmentObject private var store: DecryptStore
    let result: DecryptResult

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: result.isClean ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(result.isClean ? Palette.ok : Palette.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.isClean ? S.Result.done : S.Result.donePartial)
                        .font(.headline)
                    Text(result.output.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(result.sizeText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                stat(S.Result.statMachO, "\(result.machO)")
                Divider().frame(height: 26)
                stat(S.Result.statDecrypted, "\(result.decrypted)")
                Divider().frame(height: 26)
                stat(S.Result.statPlain, "\(result.plain)")
                Divider().frame(height: 26)
                stat(S.Result.statFailed, "\(result.failed)", warn: result.failed > 0)
            }
            .padding(.vertical, 8)
            .background(Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            if let verification = result.verification {
                Text(verification.isClean
                     ? S.Result.verified(summary: verification.summary)
                     : S.Result.verifyFailed(summary: verification.summary))
                    .font(.caption2)
                    .foregroundStyle(verification.isClean ? .secondary : Palette.warn)
            }

            HStack(spacing: 10) {
                ShareLink(item: result.output) {
                    Label(S.Result.export, systemImage: "square.and.arrow.up")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.accent))
                }
                Button {
                    store.clearResult()
                } label: {
                    Text(S.Result.again)
                        .font(.subheadline.weight(.medium))
                        .padding(.vertical, 10)
                        .padding(.horizontal, 16)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(uiColor: .tertiarySystemFill)))
                        .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
    }

    private func stat(_ title: String, _ value: String, warn: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(warn ? Palette.warn : .primary)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct FailureCard: View {
    @EnvironmentObject private var store: DecryptStore
    let message: String
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Palette.danger)
                Text(store.step).font(.headline)
                Spacer()
                Button {
                    store.clearResult()
                } label: {
                    Text(S.Result.close).font(.caption.weight(.medium))
                }
                .buttonStyle(.borderless)
            }
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                showLog.toggle()
            } label: {
                Label(showLog ? S.Run.hideLog : S.Run.showLog, systemImage: "text.alignleft")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.borderless)
            if showLog { LogView(lines: store.logs) }
        }
        .padding(16)
        .background(Palette.danger.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .stroke(Palette.danger.opacity(0.25), lineWidth: 1))
    }
}

// MARK: - 产物

private struct OutputsCard: View {
    @EnvironmentObject private var store: DecryptStore

    var body: some View {
        if !store.outputs.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                CardTitle(title: S.Result.outputs, badge: S.Result.outputsBadge(count: "\(store.outputs.count)"))
                VStack(spacing: 0) {
                    ForEach(store.outputs) { file in
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Palette.ok)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(file.sizeText) · \(file.modifiedText)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ShareLink(item: file.url) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button(role: .destructive) {
                                store.delete(file)
                            } label: {
                                Label(S.Result.deleteOutput, systemImage: "trash")
                            }
                        }
                        if file.id != store.outputs.last?.id {
                            Divider().padding(.leading, 36)
                        }
                    }
                }
            }
            .cardStyle()
        }
    }
}

// MARK: - 通用组件

private struct CardTitle: View {
    let title: String
    let badge: String?

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct EmptyRow: View {
    let text: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
    }
}

private extension View {
    func cardStyle() -> some View {
        self
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - 说明

private struct InfoSheet: View {
    @EnvironmentObject private var store: DecryptStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    block(S.Info.usageTitle, S.Info.usage)
                    block(S.Info.prereqTitle, S.Info.prereq)
                    block(S.Info.howTitle, S.Info.how)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(S.Info.envTitle).font(.headline)
                        Text(store.capability.summary + "\n" + store.capability.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineSpacing(2)
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(store.environmentLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    block(S.Info.aboutTitle, S.Info.about)
                    block(S.Info.licenseTitle, S.Info.license)
                }
                .padding(20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(S.Info.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(S.Info.done) { dismiss() }
                }
            }
        }
    }

    private func block(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
