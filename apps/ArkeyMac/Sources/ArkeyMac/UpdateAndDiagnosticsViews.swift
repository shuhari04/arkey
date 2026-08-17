import AppKit
import SwiftUI

struct UpdateCenterView: View {
    @ObservedObject var updates: ArkeyUpdateService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("软件更新")
                        .font(.system(size: 22, weight: .bold))
                    Text("所有版本均来自你本机签名并发布的 ARkey 发布库。下载后会验证签名和 SHA-256，并只打开 DMG，不会自动替换应用或刷写固件。")
                        .font(.system(size: 12))
                        .foregroundStyle(ArkeyTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(ArkeyControlButtonStyle(compact: true))
            }

            updateStatus

            HStack {
                Text("已发布版本")
                    .font(.headline)
                Spacer()
                Button("重新检查") { updates.retry() }
                    .buttonStyle(ArkeyControlButtonStyle(compact: true))
                    .disabled(isBusy)
            }

            if updates.releases.isEmpty {
                ContentUnavailableView("尚未取得发布清单", systemImage: "arrow.triangle.2.circlepath", description: Text("请检查 updates.arkey.fun 的 DNS 与 HTTPS 配置，然后重新检查。"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(updates.releases) { release in
                    HStack(spacing: 12) {
                        Image(systemName: release.version == updates.newestRelease?.version ? "arrow.down.circle.fill" : "archivebox")
                            .font(.system(size: 21))
                            .foregroundStyle(release.version == updates.newestRelease?.version ? Color.blue : ArkeyTheme.textSecondary)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("ARkey \(release.version)").font(.system(size: 14, weight: .semibold))
                                if release.version == ArkeyUpdateService.currentVersion {
                                    Text("当前版本").font(.caption2).foregroundStyle(ArkeyTheme.accent)
                                }
                            }
                            Text(release.notes.isEmpty ? "含 ARkey App、固件资源和刷写工具" : release.notes.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(ArkeyTheme.textSecondary)
                                .lineLimit(2)
                            Text("\(release.publishedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: release.size, countStyle: .file))")
                                .font(.caption2)
                                .foregroundStyle(ArkeyTheme.textTertiary)
                        }
                        Spacer()
                        Button("下载") { Task { await updates.downloadAndOpen(release) } }
                            .buttonStyle(ArkeyControlButtonStyle(tone: .accent, compact: true))
                            .disabled(isBusy)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
        .padding(24)
        .frame(width: 680, height: 560)
        .background(ArkeyTheme.canvas)
        .task { if updates.catalog == nil { await updates.checkForUpdates() } }
    }

    @ViewBuilder
    private var updateStatus: some View {
        HStack(spacing: 9) {
            Image(systemName: statusSymbol)
                .foregroundStyle(statusColor)
            Text(updates.state.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(ArkeyTheme.textSecondary)
            Spacer()
            if let date = updates.lastChecked { Text("上次检查：\(date.formatted(date: .omitted, time: .shortened))").font(.caption).foregroundStyle(ArkeyTheme.textTertiary) }
        }
        .padding(12)
        .background(ArkeyTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isBusy: Bool {
        switch updates.state {
        case .checking, .downloading, .verifying, .opening: true
        default: false
        }
    }

    private var statusSymbol: String { isBusy ? "arrow.triangle.2.circlepath" : (updates.state.failureMessage == nil ? "checkmark.circle" : "exclamationmark.triangle") }
    private var statusColor: Color { updates.state.failureMessage == nil ? (isBusy ? .blue : ArkeyTheme.accent) : ArkeyTheme.danger }
}

struct DiagnosticCenterView: View {
    @ObservedObject var diagnostics: ArkeyDiagnostics
    @Environment(\.dismiss) private var dismiss
    @State private var category: ArkeyDiagnosticCategory?
    @State private var exportMessage: String?

    var visibleEvents: [ArkeyDiagnosticEvent] {
        category == nil ? diagnostics.recentEvents : diagnostics.recentEvents.filter { $0.category == category }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("诊断中心").font(.system(size: 22, weight: .bold))
                    Text("仅记录设备与协议摘要：不会收集按键内容、序列号、提示词、工作区路径或完整 HID 报文。")
                        .font(.caption).foregroundStyle(ArkeyTheme.textSecondary)
                }
                Spacer()
                Button("关闭") { dismiss() }.buttonStyle(ArkeyControlButtonStyle(compact: true))
            }

            HStack(spacing: 9) {
                Label(diagnostics.uploadStatus, systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(ArkeyTheme.textSecondary)
                Spacer()
                Menu(category?.title ?? "全部类别") {
                    Button("全部类别") { category = nil }
                    ForEach(ArkeyDiagnosticCategory.allCases) { item in Button(item.title) { category = item } }
                }
                .buttonStyle(ArkeyControlButtonStyle(compact: true))
                Button("刷新") { diagnostics.reload() }.buttonStyle(ArkeyControlButtonStyle(compact: true))
                Button("导出 ZIP") { export() }.buttonStyle(ArkeyControlButtonStyle(tone: .accent, compact: true))
            }

            if let exportMessage {
                Text(exportMessage).font(.caption).foregroundStyle(ArkeyTheme.textSecondary)
            }

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("诊断会话").font(.headline)
                    if diagnostics.sessions.isEmpty {
                        Text("尚无会话").font(.caption).foregroundStyle(ArkeyTheme.textTertiary)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 7) {
                                ForEach(diagnostics.sessions) { item in
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.id).font(.system(.caption, design: .monospaced))
                                            Text(item.reason).font(.caption2).foregroundStyle(ArkeyTheme.textSecondary)
                                        }
                                        Spacer()
                                        Text(item.uploadState).font(.caption2).foregroundStyle(ArkeyTheme.textTertiary)
                                        Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.id, forType: .string) } label: { Image(systemName: "doc.on.doc") }
                                            .buttonStyle(ArkeyIconButtonStyle(size: 22))
                                    }
                                    .padding(8)
                                    .background(ArkeyTheme.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                            }
                        }
                    }
                }
                .frame(width: 285, alignment: .leading)

                VStack(alignment: .leading, spacing: 7) {
                    Text("最近事件").font(.headline)
                    List(visibleEvents) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.name).font(.system(.caption, design: .monospaced)).foregroundStyle(event.severity == .error ? ArkeyTheme.danger : ArkeyTheme.textPrimary)
                                Spacer()
                                Text(event.category.title).font(.caption2).foregroundStyle(ArkeyTheme.textTertiary)
                            }
                            if !event.details.isEmpty { Text(event.details.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " · ")).font(.caption2).foregroundStyle(ArkeyTheme.textSecondary).lineLimit(2) }
                            Text(event.timestamp.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(ArkeyTheme.textTertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(24)
        .frame(width: 900, height: 610)
        .background(ArkeyTheme.canvas)
        .onAppear { diagnostics.reload() }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ARkey-Diagnostics-\(Date().formatted(.iso8601.year().month().day())).zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await diagnostics.exportLogs(to: url)
                exportMessage = "已导出：\(url.lastPathComponent)"
            } catch {
                exportMessage = error.localizedDescription
            }
        }
    }
}

private extension ArkeyUpdateState {
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}
