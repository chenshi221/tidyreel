import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

struct ScanPreviewRequest: Identifiable, Equatable {
    let id = UUID()
    var connectionId: ConnectionId
    var paths: [String]
    var fileSizes: [String: Int64]
    var mode: OrganizeMode
    var scrape: Bool
    var scrapeOnly: Bool
    var mediaHint: MediaHint
    var clearSelectionOnSubmit: Bool
}

struct ScanPreviewSheet: View {
    let store: AppStore
    let request: ScanPreviewRequest
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var summary: ScanPreviewSummary?
    @State private var organizedCount: Int = 0
    @State private var errorMessage: String?
    @State private var retryNonce: Int = 0

    private var warnings: [String] {
        guard let summary else { return [] }
        return ScanPreviewService.warnings(
            paths: request.paths,
            preview: summary,
            organizedCount: organizedCount,
            l10n: l10n
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(l10n.tr("识别前预览", "Scan Preview"))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.text)

                Text(pathsSummaryText)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if request.scrapeOnly {
                        FramedTypeTag(l10n.tr("仅刮削", "Scrape Only"))
                    } else {
                        FramedTypeTag(l10n.organizeModeLabel(request.mode))
                        if request.scrape {
                            FramedTypeTag(l10n.tr("刮削", "Scrape"))
                        }
                    }
                    FramedTypeTag(
                        l10n.tr(
                            "类型：\(l10n.mediaHintLabel(request.mediaHint))",
                            "Type: \(l10n.mediaHintLabel(request.mediaHint))"
                        )
                    )
                }
                .padding(.top, 2)
            }

            if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22))
                        .foregroundStyle(palette.danger)
                    Text(l10n.tr("扫描预览失败", "Scan preview failed"))
                        .font(.system(size: TidyreelTypeScale.headline, weight: .medium))
                        .foregroundStyle(palette.text)
                    Text(localizeCoreMessage(l10n, errorMessage))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    SecondaryActionButton(l10n.retry, systemImage: "arrow.clockwise") {
                        retryNonce &+= 1
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else if let summary {
                let prefix = summary.truncated ? "≥ " : ""

                HStack(spacing: 8) {
                    statTile(
                        icon: "folder.fill",
                        label: l10n.tr("文件夹", "Folders"),
                        value: "\(prefix)\(summary.dirs)"
                    )
                    statTile(
                        icon: "film",
                        label: l10n.tr("视频", "Videos"),
                        value: "\(prefix)\(summary.videos)"
                    )
                    statTile(
                        icon: "captions.bubble",
                        label: l10n.tr("字幕", "Subtitles"),
                        value: "\(prefix)\(summary.subtitles)"
                    )
                    statTile(
                        icon: "internaldrive",
                        label: l10n.tr("大小", "Size"),
                        value: summary.bytes > 0 ? "\(prefix)\(formatBytes(summary.bytes))" : "—"
                    )
                }

                if !summary.topDirs.isEmpty {
                    let topNames = summary.topDirs.prefix(8).map { baseOf($0) }
                    let joined = topNames.joined(separator: l10n.isEn ? ", " : "、")
                    let suffix = summary.topDirs.count > 8
                        ? l10n.tr(" 等 \(summary.topDirs.count) 个", " (\(summary.topDirs.count) total)")
                        : ""
                    Text(l10n.tr("包含：\(joined)\(suffix)", "Includes: \(joined)\(suffix)"))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                        .lineLimit(3)
                }

                if !warnings.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(warnings, id: \.self) { warning in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(palette.warning)
                                    .padding(.top, 1)
                                Text(warning)
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                    .fill(palette.warning.opacity(0.10))
                            )
                        }
                    }
                }

                Text(
                    request.scrapeOnly
                        ? l10n.tr(
                            "这一步只识别，确认结果后才会写入 NFO 与海报，且不会修改任何现有文件名。",
                            "This step only matches titles. NFO and artwork are written only after review, keeping filenames untouched."
                        )
                        : l10n.tr(
                            "这一步只识别，不改任何文件。确认结果后点「开始整理」才会改名，之后也能撤销。",
                            "This step only matches titles without changing files. Renaming happens after your review and is always undoable."
                        )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textFaint)
            } else {
                VStack(spacing: 10) {
                    DashedSpinner(size: 18)
                    Text(l10n.tr("正在快速扫描…", "Scanning…"))
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
            }

            Rectangle()
                .fill(palette.line)
                .frame(height: hairlineWidth)

            HStack(spacing: 8) {
                Spacer()

                QuietTextButton(l10n.cancel) {
                    dismiss()
                }

                PrimaryActionButton(
                    warnings.isEmpty
                        ? l10n.tr("开始识别", "Start Matching")
                        : l10n.tr("仍然开始", "Continue Anyway"),
                    isDisabled: summary == nil || errorMessage != nil
                ) {
                    dismiss()
                    onConfirm()
                }
            }
        }
        .padding(22)
        .frame(width: 520)
        .background(palette.canvas)
        .task(id: retryNonce) {
            await runPreview()
        }
    }

    private var pathsSummaryText: String {
        if request.paths.count == 1, let single = request.paths.first {
            return single
        }
        let sample = request.paths.prefix(3).map { baseOf($0) }.joined(separator: l10n.isEn ? ", " : "、")
        let more = request.paths.count > 3 ? " …" : ""
        return l10n.tr(
            "\(request.paths.count) 项：\(sample)\(more)",
            "\(l10n.plural(request.paths.count, "item")): \(sample)\(more)"
        )
    }

    private func statTile(icon: String, label: String, value: String) -> some View {
        PanelBox(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12), framed: true) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13.5))
                    .foregroundStyle(palette.textMuted)

                Text(value)
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold).monospacedDigit())
                    .foregroundStyle(palette.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(label)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func runPreview() async {
        errorMessage = nil
        summary = nil
        do {
            let backend = try store.backend(for: request.connectionId)
            let result = await ScanPreviewService.preview(
                backend: backend,
                paths: request.paths,
                fileSizes: request.fileSizes,
                isCancelled: { Task.isCancelled }
            )
            guard !Task.isCancelled else { return }
            let candidateDirs = Array(Set(request.paths + result.topDirs).prefix(100))
            let orgSet = await store.arePathsOrganized(
                connection: request.connectionId,
                paths: candidateDirs
            )
            guard !Task.isCancelled else { return }
            summary = result
            organizedCount = orgSet.count
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}
