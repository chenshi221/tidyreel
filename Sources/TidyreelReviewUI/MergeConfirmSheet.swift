import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices

// MARK: - 1. Pre-Execution Folder Merge Confirmation Sheet (`merge_dialog.dart`)

struct MergeConfirmSheet: View {
    let store: AppStore
    let taskId: TaskId
    let merges: [PlanMerge]
    let mode: OrganizeMode
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    private enum ExistingFolderLoadState: Equatable {
        case loading
        case loaded([Int: Set<Int>])
        case failed
    }

    @State private var separateGroupIds: Set<GroupId> = []
    @State private var existingFolderStates: [String: ExistingFolderLoadState] = [:]
    @State private var groupsById: [GroupId: MediaGroup] = [:]
    @State private var addingByGroup: [GroupId: [Int: Set<Int>]] = [:]
    @State private var didPrecompute = false

    var body: some View {
        let review = viewModel.review

        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("合并到已有剧集文件夹？", "Merge into Existing Show Folder?"))
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                    .foregroundStyle(palette.text)

                Text(
                    l10n.tr(
                        "下面的作品会和已有的（或本次另一个文件夹里的）同一部作品放进同一个文件夹。",
                        "The titles below will be combined with an existing folder (or another folder in this batch) for the same show."
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(merges, id: \.group) { merge in
                        let g = groupsById[merge.group]
                        let match = g.flatMap { effectiveMatch($0, review?.decisions[$0.id]) }
                        let other = merge.withGroup.flatMap { groupsById[$0] }
                        let keepSeparate = separateGroupIds.contains(merge.group)

                        PanelBox(
                            padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12),
                            framed: true
                        ) {
                            HStack(alignment: .top, spacing: 12) {
                                DownsampledArtworkView(
                                    tmdbPath: match?.posterPath,
                                    width: 40,
                                    height: 60,
                                    cornerRadius: 5,
                                    fallbackSystemImage: "tv"
                                )

                                VStack(alignment: .leading, spacing: 3) {
                                    let name = match?.title ?? g?.anchorTitle ?? merge.group.value
                                    let yearStr = match?.year.map { " (\($0))" } ?? ""
                                    Text(l10n.isEn ? "\(name)\(yearStr)" : "《\(name)》\(yearStr)")
                                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                                        .foregroundStyle(palette.text)

                                    Text(
                                        keepSeparate
                                            ? separatedFolderPreview(merge: merge, group: g)
                                            : l10n.tr("合并到 \(merge.into)", "Merge into \(merge.into)")
                                    )
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.text)
                                    .textSelection(.enabled)

                                    if merge.exists {
                                        Text(existingSummaryText(for: merge.into))
                                            .font(.system(size: TidyreelTypeScale.small))
                                            .foregroundStyle(palette.textMuted)
                                    } else if let other {
                                        Text(
                                            l10n.tr(
                                                "和本次的 \(other.rootDir) 放在一起",
                                                "Combined with \(other.rootDir) from this batch"
                                            )
                                        )
                                        .font(.system(size: TidyreelTypeScale.small))
                                        .foregroundStyle(palette.textMuted)
                                    }

                                    if let adding = addingByGroup[merge.group] {
                                        Text(
                                            l10n.tr(
                                                "本次加入：\(describeEpisodeMap(adding, l10n: l10n))",
                                                "Adding: \(describeEpisodeMap(adding, l10n: l10n))"
                                            )
                                        )
                                        .font(.system(size: TidyreelTypeScale.small))
                                        .foregroundStyle(palette.textMuted)
                                    }

                                    if let g {
                                        Text(l10n.tr("本次来源：\(g.rootDir)", "Source: \(g.rootDir)"))
                                            .font(.system(size: TidyreelTypeScale.small))
                                            .foregroundStyle(palette.textMuted)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }

                                Spacer(minLength: 8)

                                SlidingSegmented(
                                    options: [
                                        (false, l10n.tr("合并", "Merge")),
                                        (true, l10n.tr("分开保留", "Keep Separate")),
                                    ],
                                    selection: keepSeparate
                                ) { wantSeparate in
                                    if wantSeparate {
                                        separateGroupIds.insert(merge.group)
                                    } else {
                                        separateGroupIds.remove(merge.group)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)

            Text(
                l10n.tr(
                    "已有的集不会被覆盖：两边有相同的集时会标为冲突，由你决定保留哪个。",
                    "Existing episodes are never overwritten; duplicate episodes are flagged as conflicts for you to resolve."
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)

            HStack(spacing: 8) {
                Spacer()
                SecondaryActionButton(l10n.cancel) {
                    viewModel.activeSheet = nil
                }
                .keyboardShortcut(.cancelAction)

                PrimaryActionButton(l10n.tr("继续", "Continue")) {
                    let chosenSeparate = separateGroupIds
                    Task {
                        await viewModel.confirmMergesAndContinue(
                            store: store,
                            taskId: taskId,
                            merges: merges,
                            separateGroupIds: chosenSeparate
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 560)
        .background(palette.canvas)
        .onAppear {
            precomputeMergeMetadataIfNeeded()
        }
        .task {
            await loadExistingFoldersIfNeeded()
        }
    }

    private func precomputeMergeMetadataIfNeeded() {
        guard !didPrecompute else { return }
        didPrecompute = true
        guard let review = viewModel.review else { return }
        groupsById = Dictionary(
            uniqueKeysWithValues: review.scan.groups.map { ($0.id, $0) }
        )
        addingByGroup = plannedAddingEpisodesByGroup(merges: merges, in: review.preview)
    }

    private func separatedFolderPreview(merge: PlanMerge, group: MediaGroup?) -> String {
        if mode == .inPlace, let group, dirOf(merge.into) == dirOf(group.rootDir) {
            return l10n.tr("保留原目录：\(group.rootDir)", "Keep original folder: \(group.rootDir)")
        }
        var n = 2
        for prev in merges {
            if prev.group == merge.group { break }
            if prev.into == merge.into && separateGroupIds.contains(prev.group) {
                n += 1
            }
        }
        return l10n.tr("独立目录：\(merge.into) (\(n))", "Separate folder: \(merge.into) (\(n))")
    }

    private func existingSummaryText(for path: String) -> String {
        switch existingFolderStates[path] ?? .loading {
        case .loading:
            return l10n.tr("已有：读取中…", "Existing: loading…")
        case .failed:
            return l10n.tr("已有文件夹（读取内容失败）", "Existing folder (failed to read contents)")
        case .loaded(let map):
            return l10n.tr(
                "已有：\(describeEpisodeMap(map, l10n: l10n))",
                "Existing: \(describeEpisodeMap(map, l10n: l10n))"
            )
        }
    }

    private func loadExistingFoldersIfNeeded() async {
        guard let connId = viewModel.review?.scan.connection,
              let backend = try? store.backend(for: connId) else {
            return
        }
        let dirs = Array(Set(merges.filter(\.exists).map(\.into)))
        for d in dirs where existingFolderStates[d] == nil {
            existingFolderStates[d] = .loading
            do {
                let eps = try await episodesInFolder(backend: backend, dir: d)
                existingFolderStates[d] = .loaded(eps)
            } catch {
                existingFolderStates[d] = .failed
            }
        }
    }
}

// MARK: - 2. Permanent Delete Confirmation Sheet (`confirmPermanentDelete` in `review_page.dart:772`)

struct PermanentDeleteConfirmSheet: View {
    let paths: [String]
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    l10n.tr(
                        "永久删除 \(paths.count) 个文件？",
                        "Permanently delete \(l10n.plural(paths.count, "file"))?"
                    )
                )
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

                Text(
                    l10n.tr(
                        "删除操作无法通过「撤销」找回。其余重命名与移动操作仍可随时撤销。",
                        "Deleted files cannot be restored via Undo. All rename and move operations remain undoable."
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
            }

            PanelBox(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12), framed: true) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(paths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "trash")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(palette.danger)
                                Text(path)
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(palette.text)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            HStack(spacing: 8) {
                Spacer()
                SecondaryActionButton(l10n.cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)

                SecondaryActionButton(
                    l10n.tr("永久删除", "Delete Permanently"),
                    systemImage: "trash",
                    isDestructive: true,
                    action: onConfirm
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 480)
        .background(palette.canvas)
    }
}

// MARK: - 3. Merge Group Into Another Group Sheet (`mergeGroups`)

struct MergeGroupSheet: View {
    let store: AppStore
    let taskId: TaskId
    let source: MediaGroup
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var pickedGroupId: GroupId?

    var body: some View {
        let decisions = viewModel.review?.decisions ?? [:]
        let candidates = (viewModel.review?.scan.groups ?? []).filter { $0.id != source.id }
        let sourceTitle = effectiveMatch(source, decisions[source.id])?.title ?? source.anchorTitle

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("合并到其他作品", "Merge into Another Title"))
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                    .foregroundStyle(palette.text)

                Text(
                    l10n.tr(
                        "将「\(sourceTitle)」中的 \(source.files.count) 个文件并入所选作品分组。",
                        "Move \(l10n.plural(source.files.count, "file")) from \"\(sourceTitle)\" into the selected group."
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
            }

            PanelBox(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4), framed: true) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(candidates) { g in
                            let m = effectiveMatch(g, decisions[g.id])
                            let title = m?.title ?? g.anchorTitle
                            let isSelected = (pickedGroupId == g.id)

                            InstantHoverRow(
                                isSelected: isSelected,
                                cornerRadius: TidyreelRadii.sm,
                                padding: EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10),
                                action: { pickedGroupId = g.id }
                            ) {
                                HStack(spacing: 10) {
                                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                        .font(.system(size: 14))
                                        .foregroundStyle(isSelected ? palette.text : palette.lineStrong)

                                    DownsampledArtworkView(
                                        tmdbPath: m?.posterPath,
                                        width: 32,
                                        height: 48,
                                        cornerRadius: 4,
                                        fallbackSystemImage: g.kind == .episode ? "tv" : "film"
                                    )

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m?.year != nil ? "\(title) (\(m!.year!))" : title)
                                            .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                                            .foregroundStyle(palette.text)
                                            .lineLimit(1)

                                        Text(
                                            "\(l10n.tr("\(g.files.count) 个文件", l10n.plural(g.files.count, "file"))) · \(g.rootDir)"
                                        )
                                        .font(.system(size: TidyreelTypeScale.small))
                                        .foregroundStyle(palette.textMuted)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    }

                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack(spacing: 8) {
                Spacer()
                SecondaryActionButton(l10n.cancel) {
                    viewModel.activeSheet = nil
                }
                .keyboardShortcut(.cancelAction)

                PrimaryActionButton(
                    l10n.tr("合并", "Merge"),
                    systemImage: "arrow.triangle.merge",
                    isDisabled: pickedGroupId == nil
                ) {
                    guard let keepId = pickedGroupId else { return }
                    viewModel.activeSheet = nil
                    Task {
                        await viewModel.mergeGroups(
                            store: store,
                            taskId: taskId,
                            keep: keepId,
                            absorb: source.id
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 490)
        .background(palette.canvas)
    }
}

// MARK: - 4. Split Files Out Into a New Group Sheet (`splitGroup`)

struct SplitGroupSheet: View {
    let store: AppStore
    let taskId: TaskId
    let source: MediaGroup
    let initialSelection: Set<String>
    @Bindable var viewModel: ReviewViewModel

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @State private var sortedFiles: [ScanFile] = []
    @State private var pickedPaths: Set<String> = []
    @State private var didInit = false

    var body: some View {
        let canConfirm = !pickedPaths.isEmpty && pickedPaths.count < sortedFiles.count

        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.tr("拆分分组", "Split Group"))
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                    .foregroundStyle(palette.text)

                Text(
                    l10n.tr(
                        "勾选要拆分到新作品的文件（原分组至少保留 1 个文件）。",
                        "Select files to move into a new group (leave at least 1 file in the original group)."
                    )
                )
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textMuted)
            }

            PanelBox(padding: EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4), framed: true) {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(sortedFiles) { file in
                            let isChecked = pickedPaths.contains(file.path)
                            let sizeStr = formatBytesOrEmpty(file.size)

                            InstantHoverRow(
                                isSelected: isChecked,
                                cornerRadius: TidyreelRadii.sm,
                                padding: EdgeInsets(top: 6.5, leading: 9, bottom: 6.5, trailing: 10),
                                action: {
                                    togglePath(file.path)
                                }
                            ) {
                                HStack(spacing: 8) {
                                    InkCheckbox(isChecked: isChecked) {
                                        togglePath(file.path)
                                    }

                                    Text(file.name)
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(palette.text)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Spacer(minLength: 6)

                                    if file.role != .video {
                                        TagBadge(roleLabel(file.role))
                                    }
                                    if !sizeStr.isEmpty {
                                        Text(sizeStr)
                                            .font(.system(size: 11.5).monospacedDigit())
                                            .foregroundStyle(palette.textFaint)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack(spacing: 8) {
                Text(
                    l10n.tr(
                        "已选 \(pickedPaths.count) / \(sortedFiles.count)",
                        "Selected \(pickedPaths.count) / \(sortedFiles.count)"
                    )
                )
                .font(.system(size: TidyreelTypeScale.small).monospacedDigit())
                .foregroundStyle(pickedPaths.count >= sortedFiles.count ? palette.warning : palette.textMuted)

                if !pickedPaths.isEmpty {
                    UnderlinedLinkText(l10n.clear) {
                        pickedPaths.removeAll()
                    }
                }

                Spacer()

                SecondaryActionButton(l10n.cancel) {
                    viewModel.activeSheet = nil
                }
                .keyboardShortcut(.cancelAction)

                PrimaryActionButton(
                    l10n.tr("拆分 (\(pickedPaths.count))", "Split (\(pickedPaths.count))"),
                    systemImage: "scissors",
                    isDisabled: !canConfirm
                ) {
                    let selected = pickedPaths
                    viewModel.activeSheet = nil
                    Task {
                        await viewModel.splitGroup(
                            store: store,
                            taskId: taskId,
                            group: source.id,
                            filePaths: selected
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 520)
        .background(palette.canvas)
        .onAppear {
            guard !didInit else { return }
            didInit = true
            sortedFiles = source.files.sorted { $0.path < $1.path }
            pickedPaths = initialSelection
        }
    }

    private func togglePath(_ path: String) {
        if pickedPaths.contains(path) {
            pickedPaths.remove(path)
        } else {
            pickedPaths.insert(path)
        }
    }

    private func roleLabel(_ role: FileRole) -> String {
        switch role {
        case .video: return l10n.tr("视频", "Video")
        case .subtitle: return l10n.tr("字幕", "Sub")
        case .sidecar: return l10n.tr("附属", "Sidecar")
        case .junk: return l10n.tr("垃圾", "Junk")
        case .other: return l10n.tr("其他", "Other")
        }
    }
}

// MARK: - 5. Keyboard Shortcuts Sheet (`_showShortcutsSheet` in `review_page.dart:643-700`)

struct ShortcutsHelpSheet: View {
    let onClose: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        let rows: [(key: String, desc: String)] = [
            ("↑ / ↓", l10n.tr("切换左侧作品", "Switch title in sidebar")),
            ("← / →", l10n.tr("切换季标签 / 文件夹", "Switch season / folder tab")),
            (l10n.tr("空格", "Space"), l10n.tr("勾选或取消当前作品", "Toggle current title")),
            ("⌘F", l10n.tr("聚焦作品搜索框", "Focus title search")),
            ("⌘↩", l10n.tr("开始整理", "Start organizing")),
            ("⌘ + Click", l10n.tr("多选文件以拆分分组", "Multi-select files to split")),
        ]

        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.tr("快捷键", "Keyboard Shortcuts"))
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

            PanelBox(padding: EdgeInsets(), framed: true) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { idx, item in
                        HStack {
                            Text(item.desc)
                                .font(.system(size: TidyreelTypeScale.body))
                                .foregroundStyle(palette.text)

                            Spacer(minLength: 16)

                            Text(item.key)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(palette.text)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                        .fill(palette.sidebar)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                                        .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
                                )
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)

                        if idx < rows.count - 1 {
                            Rectangle()
                                .fill(palette.line)
                                .frame(height: hairlineWidth)
                        }
                    }
                }
            }

            HStack {
                Spacer()
                SecondaryActionButton(l10n.close, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 2)
        }
        .padding(EdgeInsets(top: 18, leading: 20, bottom: 16, trailing: 20))
        .frame(width: 360)
        .background(palette.canvas)
    }
}
