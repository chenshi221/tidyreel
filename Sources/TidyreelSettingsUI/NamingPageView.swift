import AppKit
import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelPlanner
import TidyreelServices
import UniformTypeIdentifiers

private struct PendingPresetSelection: Identifiable {
    var id: String { player.rawValue }
    let player: TargetPlayer
}

public struct NamingPageView: View {
    public let store: AppStore

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var isTv: Bool = false
    @State private var pendingPresetSwitch: PendingPresetSelection? = nil
    @State private var isImportSheetPresented: Bool = false

    public init(store: AppStore) {
        self.store = store
    }

    private var profile: NamingProfile {
        store.namingProfile
    }

    private var isPresetCustomized: Bool {
        let localizedPreset = AppL10n.localizedPlayerPreset(profile.player, isEn: l10n.isEn)
        let rawPreset = NamingProfile.forPlayer(profile.player)
        return profile != localizedPreset && profile != rawPreset
    }

    public var body: some View {
        PageScaffoldView(
            title: l10n.tr("命名规则", "Naming Rules")
        ) {
            SlidingSegmented(
                options: [
                    (false, l10n.movie),
                    (true, l10n.tvShow),
                ],
                selection: isTv
            ) { next in
                isTv = next
            }

            playerPresetMenu

            exportImportMenu
        } content: {
            GeometryReader { geo in
                let availableWidth = max(0, geo.size.width - 24)
                let leftWidth = floor(availableWidth * 11.0 / 20.0)
                let rightWidth = max(0, availableWidth - leftWidth)

                HStack(alignment: .top, spacing: 24) {
                    NamingOptionsColumnView(
                        store: store,
                        isTv: isTv
                    )
                    .frame(width: leftWidth)

                    NamingLivePreviewColumnView(
                        store: store,
                        isTv: isTv
                    )
                    .padding(.top, 22)
                    .frame(width: rightWidth)
                }
            }
            .padding(.leading, 48)
            .padding(.trailing, 40)
            .padding(.bottom, 0)
        }
        .background(palette.canvas)
        .sheet(item: $pendingPresetSwitch) { pending in
            ConfirmActionSheet(
                title: l10n.tr(
                    "切换到 \(pending.player.displayName) 预设？",
                    "Switch to \(pending.player.displayName) preset?"
                ),
                message: l10n.tr(
                    "切换播放器预设会重置电影和剧集的命名选项、自定义模板以及替换规则。",
                    "Switching player presets resets movie and TV naming options, custom templates, and rewrite rules."
                ),
                confirmLabel: l10n.tr("切换并重置", "Switch & Reset")
            ) {
                store.setNamingProfile(AppL10n.localizedPlayerPreset(pending.player, isEn: l10n.isEn))
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(isPresented: $isImportSheetPresented) {
            ImportNamingBundleSheet(store: store)
                .environment(\.palette, palette)
                .environment(\.l10n, l10n)
        }
    }

    // MARK: - Header Menus (`_PlayerMenu` & `_ExportImportMenu`)

    private var playerPresetMenu: some View {
        Menu {
            ForEach(TargetPlayer.allCases, id: \.self) { target in
                Button {
                    selectPlayer(target)
                } label: {
                    if target == profile.player && !isPresetCustomized {
                        Label(target.displayName, systemImage: "checkmark")
                    } else {
                        Text(target.displayName)
                    }
                }
            }
        } label: {
            HeaderMenuPillLabel(
                systemImage: "play.rectangle",
                title: profile.player.displayName,
                showsChevron: true
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.tr("目标播放器", "Target player"))
    }

    private var exportImportMenu: some View {
        Menu {
            Button {
                let json = NamingExportBundle.encode(profile: store.namingProfile, rules: store.titleRules)
                _ = NSPasteboard.general.clearContents()
                _ = NSPasteboard.general.setString(json, forType: .string)
                store.showToast(
                    l10n.tr("已复制命名与片名规则 JSON 到剪贴板", "Copied naming & title rules JSON to clipboard")
                )
            } label: {
                Label(l10n.tr("导出到剪贴板", "Copy JSON to Clipboard"), systemImage: "doc.on.clipboard")
            }

            Button {
                exportNamingBundleToFile()
            } label: {
                Label(l10n.tr("导出为 JSON 文件", "Export to JSON File"), systemImage: "square.and.arrow.up")
            }

            Divider()

            Button {
                isImportSheetPresented = true
            } label: {
                Label(l10n.tr("导入 JSON…", "Import JSON…"), systemImage: "square.and.arrow.down")
            }
        } label: {
            HeaderMenuPillLabel(
                systemImage: "arrow.up.arrow.down",
                title: l10n.tr("导出 / 导入", "Export / Import")
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.tr("导出或导入命名与片名规则", "Export or import naming & title rules"))
    }

    private func selectPlayer(_ next: TargetPlayer) {
        if next == profile.player && !isPresetCustomized { return }
        if isPresetCustomized {
            pendingPresetSwitch = PendingPresetSelection(player: next)
        } else {
            store.setNamingProfile(AppL10n.localizedPlayerPreset(next, isEn: l10n.isEn))
        }
    }

    private func exportNamingBundleToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "tidyreel-naming.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let json = NamingExportBundle.encode(profile: store.namingProfile, rules: store.titleRules)
        do {
            try json.write(to: url, atomically: true, encoding: .utf8)
            store.showToast(
                l10n.tr("已导出到 \(url.path)", "Exported to \(url.path)")
            )
        } catch {
            store.showToast(
                l10n.tr("导出失败：\(error.localizedDescription)", "Export failed: \(error.localizedDescription)")
            )
        }
    }
}

// MARK: - Left Options Column (`_OptionsPanel` + `_TitleRulesSection`, 11/20 width)

private struct NamingOptionsColumnView: View {
    let store: AppStore
    let isTv: Bool

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    @Environment(\.tidyreelReduceMotion) private var reduceMotion

    @State private var draggedField: NameField? = nil

    private var profile: NamingProfile {
        store.namingProfile
    }

    private var options: NamingOptions {
        isTv ? profile.tv : profile.movie
    }

    private var isCustomTemplateActive: Bool {
        options.customTemplate != nil
    }

    private var visibleOrderFields: [NameField] {
        options.order.filter { field in
            isTv || (field != .episode && field != .episodeTitle)
        }
    }

    private static let folderVars = [
        "{title}", "{en_title}", "{original_title}", "{year}", "{tmdbid}", "{tmdb_tag}",
    ]

    private static let movieCustomVars = [
        "{title}", "{en_title}", "{original_title}", "{year}",
        "{extra_info}", "{group}", "{tmdbid}", "{tmdb_tag}",
    ]

    private static let tvCustomVars = [
        "{title}", "{en_title}", "{original_title}", "{year}",
        "{season:02}", "{episode:02}", "{episode_title}",
        "{extra_info}", "{group}", "{tmdbid}", "{tmdb_tag}",
    ]

    private static let seasonPresets: [(label: String, template: String)] = [
        ("Season 01", "Season {season:02}"),
        ("Season 1", "Season {season}"),
        ("season 01", "season {season:02}"),
        ("S01", "S{season:02}"),
        ("第 1 季", "第 {season} 季"),
    ]

    private func editOptions(_ mutate: (inout NamingOptions) -> Void) {
        var next = store.namingProfile
        if isTv {
            mutate(&next.tv)
        } else {
            mutate(&next.movie)
        }
        store.setNamingProfile(next)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    titleSection
                    if isTv {
                        episodesSection
                    }
                    additionalTagsSection
                    fieldOrderSection
                }
                .opacity(isCustomTemplateActive ? 0.45 : 1.0)
                .disabled(isCustomTemplateActive)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isCustomTemplateActive)

                foldersSection

                advancedSection

                rewriteRulesSection

                SettingsDivider()
                    .padding(.top, 22)

                TitleRulesSectionView(store: store)
            }
            .padding(.bottom, 28)
        }
    }

    // MARK: 1. 标题 (Title & Year)

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("标题", "Title"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("标题语言", "Title language"),
                        caption: l10n.isEn ? "Falls back to original title when no English title exists" : nil
                    ) {
                        SlidingSegmented(
                            options: [
                                (TitleLanguage.chineseFirst, l10n.tr("中文优先", "Chinese")),
                                (TitleLanguage.englishFirst, l10n.tr("英文（原名）优先", "English")),
                            ],
                            selection: options.titleLanguage
                        ) { val in
                            editOptions { $0.titleLanguage = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("同时用两种语言", "Bilingual titles"),
                        caption: l10n.tr("如：老友记.Friends", "e.g. Friends.老友记")
                    ) {
                        InkSwitch(isOn: options.bilingual) { val in
                            editOptions { $0.bilingual = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("年份", "Year")
                    ) {
                        HStack(spacing: 8) {
                            if options.includeYear {
                                SlidingSegmented(
                                    options: [
                                        (false, "1999"),
                                        (true, "(1999)"),
                                    ],
                                    selection: options.yearInParens
                                ) { inParens in
                                    editOptions { $0.yearInParens = inParens }
                                }
                            }

                            InkSwitch(isOn: options.includeYear) { val in
                                editOptions { $0.includeYear = val }
                            }
                        }
                    }

                    if isTv {
                        SettingsDivider()

                        SettingRow(
                            title: l10n.tr("剧集年份取哪个", "Series year")
                        ) {
                            SlidingSegmented(
                                options: [
                                    (ShowYearSource.firstSeason, l10n.tr("首季年份", "First season")),
                                    (ShowYearSource.seasonAir, l10n.tr("当季首播年份", "This season")),
                                ],
                                selection: options.showYear
                            ) { src in
                                editOptions { $0.showYear = src }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: 2. 季集 (Episodes — TV only)

    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("季集", "Episodes"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 12) {
                        Text(l10n.tr("季集格式", "Episode format"))
                            .font(.system(size: TidyreelTypeScale.body))
                            .foregroundStyle(palette.text)

                        Spacer(minLength: 8)

                        FlowWrapLayout(spacing: 4, lineSpacing: 4) {
                            ForEach(EpisodeStyle.allCases, id: \.self) { style in
                                MonoStyleChip(
                                    label: style.exampleLabel,
                                    isSelected: options.episodeStyle == style
                                ) {
                                    editOptions { $0.episodeStyle = style }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("分集标题", "Episode title"),
                        caption: l10n.tr(
                            "从 TMDB 取每集的名字加在文件名里",
                            "Include each episode title from TMDB in the filename"
                        )
                    ) {
                        InkSwitch(isOn: options.episodeTitle) { val in
                            editOptions { $0.episodeTitle = val }
                        }
                    }
                }
            }
        }
    }

    // MARK: 3. 附加内容 (Additional Tags)

    private var additionalTagsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("附加内容", "Additional Tags"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("附加信息", "Extra info"),
                        caption: l10n.tr(
                            "保留分辨率、HDR、音轨，如 2160p.DV",
                            "Keep resolution, HDR, and audio tags, e.g. 2160p.DV"
                        )
                    ) {
                        InkSwitch(isOn: options.extraInfo) { val in
                            editOptions { $0.extraInfo = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("发布组", "Release group"),
                        caption: l10n.tr("在末尾加 -GRP", "Append -GRP at the end")
                    ) {
                        InkSwitch(isOn: options.releaseGroup) { val in
                            editOptions { $0.releaseGroup = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("TMDB ID 标签", "TMDB ID tag"),
                        caption: "{tmdb-12345}"
                    ) {
                        InkSwitch(isOn: options.tmdbIdTag) { val in
                            editOptions { $0.tmdbIdTag = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("分隔符", "Separator")
                    ) {
                        SlidingSegmented(
                            options: [
                                (".", " . "),
                                ("_", " _ "),
                                (" ", l10n.tr("空格", "Space")),
                                ("-", " - "),
                            ],
                            selection: options.separator
                        ) { sep in
                            editOptions { $0.separator = sep }
                        }
                    }
                }
            }
        }
    }

    // MARK: 4. 字段顺序 (Field Order — vertical reorderable list matching `naming_page.dart:1221`)

    private var fieldOrderSection: some View {
        let fields = visibleOrderFields
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("字段顺序", "Field Order"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    ForEach(Array(fields.enumerated()), id: \.element) { index, field in
                        if index > 0 {
                            SettingsDivider()
                        }
                        FieldOrderRowView(
                            index: index,
                            total: fields.count,
                            label: field.localizedLabel(l10n),
                            isDragging: draggedField == field,
                            onMoveUp: { moveVisibleField(from: index, to: index - 1) },
                            onMoveDown: { moveVisibleField(from: index, to: index + 1) }
                        )
                        .onDrag {
                            draggedField = field
                            return NSItemProvider(object: field.rawValue as NSString)
                        }
                        .onDrop(
                            of: [UTType.plainText],
                            delegate: NameFieldDropDelegate(
                                targetField: field,
                                visibleFields: fields,
                                draggedField: $draggedField,
                                onMove: { fromIdx, toIdx in
                                    moveVisibleField(from: fromIdx, to: toIdx)
                                }
                            )
                        )
                    }
                }
            }
        }
    }

    private func moveVisibleField(from sourceIndex: Int, to destinationIndex: Int) {
        var visible = visibleOrderFields
        guard sourceIndex >= 0,
              sourceIndex < visible.count,
              destinationIndex >= 0,
              destinationIndex < visible.count,
              sourceIndex != destinationIndex else {
            return
        }
        let item = visible.remove(at: sourceIndex)
        visible.insert(item, at: destinationIndex)
        editOptions { opts in
            let hidden = opts.order.filter { !visible.contains($0) }
            opts.order = visible + hidden
        }
    }

    // MARK: 5. 文件夹 (Folders)

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("文件夹", "Folders"))

            PanelBox(padding: EdgeInsets(top: 8, leading: 8, bottom: 10, trailing: 14)) {
                VStack(alignment: .leading, spacing: 4) {
                    FormRow(
                        label: isTv ? l10n.tr("剧集目录", "TV folder") : l10n.tr("电影目录", "Movie folder"),
                        labelWidth: 96
                    ) {
                        InkTextField(
                            placeholder: isTv ? l10n.tr("剧集", "TV Shows") : l10n.tr("电影", "Movies"),
                            text: Binding(
                                get: { isTv ? profile.tvDir : profile.movieDir },
                                set: { newVal in
                                    var next = store.namingProfile
                                    if isTv {
                                        next.tvDir = newVal
                                    } else {
                                        next.movieDir = newVal
                                    }
                                    store.setNamingProfile(next)
                                }
                            )
                        )
                    }

                    FormRow(
                        label: l10n.tr("作品文件夹", "Title folder"),
                        labelWidth: 96
                    ) {
                        TemplateTextOption(
                            placeholder: "{title} ({year})",
                            text: Binding(
                                get: { options.folderTemplate },
                                set: { val in editOptions { $0.folderTemplate = val } }
                            ),
                            variables: Self.folderVars
                        )
                    }

                    if isTv {
                        FormRow(
                            label: l10n.tr("季文件夹", "Season folder"),
                            labelWidth: 96
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                FlowWrapLayout(spacing: 4, lineSpacing: 4) {
                                    ForEach(Self.seasonPresets, id: \.label) { preset in
                                        MonoStyleChip(
                                            label: preset.label,
                                            isSelected: options.seasonFolderTemplate == preset.template
                                        ) {
                                            editOptions { $0.seasonFolderTemplate = preset.template }
                                        }
                                    }
                                }

                                TemplateTextOption(
                                    placeholder: "Season {season:02}",
                                    text: Binding(
                                        get: { options.seasonFolderTemplate },
                                        set: { val in editOptions { $0.seasonFolderTemplate = val } }
                                    ),
                                    variables: ["{season}", "{season:02}"]
                                )
                            }
                        }

                        FormRow(
                            label: l10n.tr("单季剧", "Single season"),
                            labelWidth: 96,
                            help: l10n.tr(
                                "打开：只有一季的剧也放进季文件夹。多季剧总是分季文件夹",
                                "When on, single-season shows also get a season folder. Multi-season shows always use season folders."
                            )
                        ) {
                            InkSwitch(isOn: options.singleSeasonFolder) { val in
                                editOptions { $0.singleSeasonFolder = val }
                            }
                            .padding(.top, 4)
                        }
                    }
                }
            }
        }
    }

    // MARK: 6. 高级 (Advanced Custom Template)

    private var advancedSection: some View {
        let vars = isTv ? Self.tvCustomVars : Self.movieCustomVars
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("高级", "Advanced"))

            PanelBox(padding: EdgeInsets()) {
                VStack(alignment: .leading, spacing: 0) {
                    SettingRow(
                        title: l10n.tr("直接编辑模板", "Custom filename template"),
                        caption: l10n.tr(
                            "开启后上面的文件名选项变为只读，文件夹设置仍可修改",
                            "Locks the filename options above; folder settings remain editable"
                        )
                    ) {
                        InkSwitch(isOn: isCustomTemplateActive) { enabled in
                            editOptions { opts in
                                opts.customTemplate = enabled ? compileTemplate(opts, isMovie: !isTv) : nil
                            }
                        }
                    }

                    if let custom = options.customTemplate {
                        TemplateTextOption(
                            placeholder: isTv ? "{title}[.{en_title}][.{year}].S{season:02}E{episode:02}" : "{title}[.{en_title}][.{year}]",
                            text: Binding(
                                get: { custom },
                                set: { val in editOptions { $0.customTemplate = val } }
                            ),
                            monospaced: true,
                            variables: vars
                        )
                        .padding(.horizontal, 14)
                        .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    // MARK: 7. 替换规则 (Rewrite Rules)

    private var rewriteRulesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("替换规则", "Rewrite Rules")) {
                HStack(spacing: 6) {
                    TagBadge(isTv ? l10n.tr("仅剧集", "TV only") : l10n.tr("仅电影", "Movies only"))
                    QuietTextButton(
                        l10n.tr("添加", "Add"),
                        systemImage: "plus",
                        fontSize: TidyreelTypeScale.small
                    ) {
                        editOptions { $0.rewrites.append(NameRewrite("", "")) }
                    }
                }
            }

            PanelBox(padding: EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)) {
                if options.rewrites.isEmpty {
                    Text(
                        l10n.tr(
                            "生成名称后再按正则查找替换，文件和文件夹都生效。比如把 Season (\\d+) 换成 S$1",
                            "Apply regex find-and-replace to generated file and folder names. For example, replace Season (\\d+) with S$1"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    RegexRewriteEditorList(
                        items: options.rewrites,
                        onUpdate: { idx, updated in
                            editOptions { opts in
                                guard idx < opts.rewrites.count else { return }
                                opts.rewrites[idx] = updated
                            }
                        },
                        onRemove: { idx in
                            editOptions { opts in
                                guard idx < opts.rewrites.count else { return }
                                opts.rewrites.remove(at: idx)
                            }
                        }
                    )
                }
            }
        }
    }
}

private struct FieldOrderRowView: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    let index: Int
    let total: Int
    let label: String
    let isDragging: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index + 1)")
                .font(.system(size: TidyreelTypeScale.small))
                .monospacedDigit()
                .foregroundStyle(palette.textFaint)
                .frame(width: 14, alignment: .leading)

            Text(label)
                .font(.system(size: TidyreelTypeScale.body))
                .foregroundStyle(palette.text)

            Spacer()

            if isHovered {
                HStack(spacing: 2) {
                    QuietIconButton(
                        systemImage: "chevron.up",
                        tooltip: l10n.tr("上移", "Move up"),
                        iconSize: 11,
                        isDisabled: index == 0,
                        action: onMoveUp
                    )
                    QuietIconButton(
                        systemImage: "chevron.down",
                        tooltip: l10n.tr("下移", "Move down"),
                        iconSize: 11,
                        isDisabled: index >= total - 1,
                        action: onMoveDown
                    )
                }
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13))
                .foregroundStyle(palette.textFaint)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(isDragging ? palette.selected : (isHovered ? palette.hover : palette.panel))
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
    }
}

// MARK: - Right Live Preview Column (`_Preview` in `naming_page.dart:642`, 9/20 width)

private struct ScenarioPreviewKey: Equatable {
    let profile: NamingProfile
    let isTv: Bool
    let scenarioId: String
}

private struct CustomPreviewKey: Equatable {
    let rawInput: String
    let profile: NamingProfile
    let isTv: Bool
}

private struct NamingLivePreviewColumnView: View {
    let store: AppStore
    let isTv: Bool

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var movieScenarioId: String = "standard"
    @State private var tvScenarioId: String = "standard"
    @State private var customInput: String = ""
    @State private var cachedScenarioPreview: RenderedNamingPreview
    @State private var cachedCustomPreview: NamingPreviewEngine.CustomTesterResult? = nil

    @MainActor
    private static let airDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    init(store: AppStore, isTv: Bool) {
        self.store = store
        self.isTv = isTv
        let scenarios = isTv ? NamingSampleData.tvScenarios : NamingSampleData.movieScenarios
        self._cachedScenarioPreview = State(
            initialValue: NamingPreviewEngine.renderScenario(
                profile: store.namingProfile,
                isMovie: !isTv,
                scenario: scenarios[0]
            )
        )
    }

    private var profile: NamingProfile {
        store.namingProfile
    }

    private var options: NamingOptions {
        isTv ? profile.tv : profile.movie
    }

    var body: some View {
        let scenarios = isTv ? NamingSampleData.tvScenarios : NamingSampleData.movieScenarios
        let selectedId = isTv ? tvScenarioId : movieScenarioId
        let scenario = scenarios.first(where: { $0.id == selectedId }) ?? scenarios[0]
        let scenarioKey = ScenarioPreviewKey(
            profile: profile,
            isTv: isTv,
            scenarioId: scenario.id
        )
        let customKey = CustomPreviewKey(
            rawInput: customInput,
            profile: profile,
            isTv: isTv
        )
        let preview = cachedScenarioPreview
        let customPreview = cachedCustomPreview

        var tree: [(text: String, isError: Bool)] = [
            (preview.typeDirectory, false),
            (preview.workFolder.localizedDisplay(l10n), preview.workFolder.isError),
        ]
        if let season = preview.seasonFolder {
            tree.append((season.localizedDisplay(l10n), season.isError))
        }

        return ScrollView(.vertical) {
            PanelBox(padding: EdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)) {
                VStack(alignment: .leading, spacing: 0) {
                    // Header + Player Tag
                    HStack {
                        Text(l10n.tr("实时示例", "Live Preview"))
                            .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                            .foregroundStyle(palette.text)
                        Spacer()
                        TagBadge(profile.player.displayName)
                    }
                    .padding(.bottom, 10)

                    // Scenario Switcher Chips
                    FlowWrapLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(scenarios, id: \.id) { item in
                            MonoStyleChip(
                                label: item.localizedLabel(l10n),
                                isSelected: scenario.id == item.id,
                                isMonospaced: false
                            ) {
                                if isTv {
                                    tvScenarioId = item.id
                                } else {
                                    movieScenarioId = item.id
                                }
                            }
                        }
                    }
                    .padding(.bottom, 14)

                    // Original Filename -> Renamed
                    Text(l10n.tr("原文件名", "Original filename"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .padding(.bottom, 4)

                    fileLine(
                        systemImage: "doc",
                        text: preview.originalFilename,
                        color: palette.textFaint
                    )

                    Image(systemName: "arrow.down")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textMuted)
                        .padding(.vertical, 8)

                    Text(l10n.tr("整理后", "Renamed"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .padding(.bottom, 4)

                    renamedBox(for: preview.fileName)
                        .padding(.bottom, 18)

                    // Directory Tree Preview
                    Text(l10n.tr("移动到媒体库时", "Library path"))
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .padding(.bottom, 6)

                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tree.enumerated()), id: \.offset) { idx, node in
                            fileLine(
                                systemImage: node.isError ? "exclamationmark.triangle" : "folder.fill",
                                text: node.text,
                                color: node.isError ? palette.danger : palette.textMuted
                            )
                            .padding(.leading, CGFloat(idx) * 16)
                        }

                        if let finalFile = preview.fileName.text {
                            fileLine(
                                systemImage: "film",
                                text: finalFile,
                                color: palette.text
                            )
                            .padding(.leading, CGFloat(tree.count) * 16)
                        }
                    }

                    if isTv {
                        let seasonDisplay = preview.seasonFolderSample ?? options.seasonFolderTemplate
                        let folderDisplay = preview.workFolder.text ?? "…"
                        let fileDisplay = preview.fileName.text ?? "…"
                        Text(
                            options.singleSeasonFolder
                                ? l10n.tr(
                                    "单季剧也会建季文件夹（\(seasonDisplay)）",
                                    "Single-season shows also use a season folder (\(seasonDisplay))"
                                )
                                : l10n.tr(
                                    "单季剧省略季文件夹：\(preview.typeDirectory)/\(folderDisplay)/\(fileDisplay)",
                                    "Single-season shows skip season folder: \(preview.typeDirectory)/\(folderDisplay)/\(fileDisplay)"
                                )
                        )
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.textFaint)
                        .lineSpacing(1.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 10)
                    }

                    SettingsDivider()
                        .padding(.vertical, 14)

                    // Custom Filename Live Parser / Tester
                    Text(l10n.tr("自定义测试", "Custom Filename Tester"))
                        .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                        .foregroundStyle(palette.text)
                        .padding(.bottom, 4)

                    Text(
                        l10n.tr(
                            "粘贴任意真实文件名（或带目录路径），实时查看解析字段与目标文件名",
                            "Paste any filename (or path) to inspect parsed fields and the rendered target name"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)

                    InkTextField(
                        placeholder: l10n.tr(
                            "如 [VCB-Studio] Frieren [01][Ma10p_1080p].mkv",
                            "e.g. [VCB-Studio] Frieren [01][Ma10p_1080p].mkv"
                        ),
                        text: $customInput,
                        icon: "flask",
                        monospaced: true
                    ) {
                        if !customInput.isEmpty {
                            Button {
                                customInput = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(palette.textFaint)
                            }
                            .buttonStyle(.plain)
                            .help(l10n.clear)
                        }
                    }

                    if let customPreview {
                        FlowWrapLayout(spacing: 6, lineSpacing: 6) {
                            parsedFieldChip(
                                label: l10n.tr("类型", "Kind"),
                                value: kindLabel(customPreview.parsed.kind)
                            )
                            parsedFieldChip(
                                label: l10n.tr("标题", "Title"),
                                value: customPreview.parsed.title ?? "—"
                            )
                            parsedFieldChip(
                                label: l10n.tr("年份", "Year"),
                                value: customPreview.parsed.year.map(String.init) ?? "—"
                            )
                            parsedFieldChip(
                                label: l10n.tr("季集", "Episode"),
                                value: episodeSummary(customPreview.parsed)
                            )
                            parsedFieldChip(
                                label: l10n.tr("版本", "Edition"),
                                value: versionSummary(customPreview.parsed)
                            )
                            parsedFieldChip(
                                label: l10n.tr("附加信息", "Extra"),
                                value: extraSummary(customPreview.parsed)
                            )
                            parsedFieldChip(
                                label: l10n.tr("外部ID", "External ID"),
                                value: customPreview.parsed.externalId?.description ?? "—"
                            )
                            parsedFieldChip(
                                label: l10n.tr("置信度", "Confidence"),
                                value: "\(Int((customPreview.parsed.confidence * 100).rounded()))%",
                                valueColor: confidenceColor(customPreview.parsed.confidence)
                            )
                        }
                        .padding(.top, 10)

                        Text(
                            l10n.tr(
                                "当前规则目标文件名（按\(customPreview.isTv ? "剧集" : "电影")规则）",
                                "Target filename (\(customPreview.isTv ? "TV" : "Movie") rules)"
                            )
                        )
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(palette.textMuted)
                        .padding(.top, 10)
                        .padding(.bottom, 4)

                        renamedBox(for: customPreview.renderedName)
                    }
                }
            }
            .padding(.bottom, 28)
        }
        .onChange(of: scenarioKey) { _, next in
            updateScenarioPreview(for: next)
        }
        .onChange(of: customKey) { _, next in
            updateCustomPreview(for: next)
        }
        .onAppear {
            updateScenarioPreview(for: scenarioKey)
            updateCustomPreview(for: customKey)
        }
    }

    private func updateScenarioPreview(for key: ScenarioPreviewKey) {
        let scenarios = key.isTv ? NamingSampleData.tvScenarios : NamingSampleData.movieScenarios
        let scenario = scenarios.first(where: { $0.id == key.scenarioId }) ?? scenarios[0]
        cachedScenarioPreview = NamingPreviewEngine.renderScenario(
            profile: key.profile,
            isMovie: !key.isTv,
            scenario: scenario
        )
    }

    private func updateCustomPreview(for key: CustomPreviewKey) {
        let trimmed = key.rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            cachedCustomPreview = nil
        } else {
            cachedCustomPreview = NamingPreviewEngine.previewCustomInput(
                rawInput: trimmed,
                profile: key.profile,
                parser: store.parser,
                fallbackIsTv: key.isTv
            )
        }
    }

    private func fileLine(systemImage: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12.5))
                .foregroundStyle(color)
                .padding(.top, 2)

            Text(text)
                .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                .foregroundStyle(color)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func renamedBox(for rendered: RenderedNamingText) -> some View {
        fileLine(
            systemImage: "film",
            text: rendered.localizedDisplay(l10n),
            color: rendered.isError ? palette.danger : palette.text
        )
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(rendered.isError ? palette.danger.opacity(0.06) : palette.sidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(
                    rendered.isError ? palette.danger.opacity(0.40) : palette.line,
                    lineWidth: hairlineWidth
                )
        )
    }

    private func parsedFieldChip(label: String, value: String, valueColor: Color? = nil) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.textFaint)
            Text(value)
                .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? palette.text)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(palette.sidebar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(palette.line, lineWidth: hairlineWidth)
        )
    }

    private func kindLabel(_ kind: MediaKind) -> String {
        switch kind {
        case .movie: return l10n.movie
        case .episode: return l10n.tvShow
        case .special: return l10n.specials
        case .extra: return l10n.tr("花絮", "Extras")
        case .unknown: return l10n.tr("未知", "Unknown")
        }
    }

    private func episodeSummary(_ parsed: ParsedName) -> String {
        if let first = parsed.episodes.first {
            let s = parsed.season.map { String(format: "S%02d", $0) } ?? ""
            let eStart = String(format: "E%02d", first)
            let eEnd: String
            if parsed.episodes.count > 1, let last = parsed.episodes.last, last > first {
                eEnd = String(format: "-E%02d", last)
            } else {
                eEnd = ""
            }
            return "\(s)\(eStart)\(eEnd)"
        }
        if let absEp = parsed.absolute {
            return l10n.tr("第 \(absEp) 集（绝对集）", "Ep \(absEp) (absolute)")
        }
        if let airDate = parsed.airDate {
            let d = Self.airDateFormatter.string(from: airDate)
            return l10n.tr("日期 \(d)", "Date \(d)")
        }
        if let season = parsed.season {
            return String(format: "S%02d", season)
        }
        return "—"
    }

    private func versionSummary(_ parsed: ParsedName) -> String {
        var parts: [String] = []
        if let ed = parsed.edition, !ed.isEmpty { parts.append(ed) }
        if let pt = parsed.partLabel, !pt.isEmpty { parts.append(pt) }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func extraSummary(_ parsed: ParsedName) -> String {
        var parts: [String] = []
        if let ex = parsed.extraInfo, !ex.isEmpty {
            parts.append(ex)
        } else if let res = parsed.resolution, !res.isEmpty {
            parts.append(res)
        }
        if let grp = parsed.group, !grp.isEmpty {
            parts.append(l10n.tr("发布组 \(grp)", "Group \(grp)"))
        }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.8 { return palette.success }
        if confidence >= 0.5 { return palette.warning }
        return palette.danger
    }
}

// MARK: - Drag & Drop Delegate for NameField Reordering

private struct NameFieldDropDelegate: DropDelegate {
    let targetField: NameField
    let visibleFields: [NameField]
    @Binding var draggedField: NameField?
    let onMove: (Int, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged = draggedField,
              dragged != targetField,
              let fromIdx = visibleFields.firstIndex(of: dragged),
              let toIdx = visibleFields.firstIndex(of: targetField) else {
            return
        }
        onMove(fromIdx, toIdx)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedField = nil
        return true
    }
}

// MARK: - Import Naming JSON Sheet (`_ImportNamingDialog` in `naming_page.dart:401`)

private struct ImportNamingBundleSheet: View {
    let store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var rawJson: String = ""
    @State private var fileLoadError: String? = nil
    @State private var cachedValidation: Result<NamingExportBundle, NamingBundleError>? = nil

    private static func validateJson(
        _ raw: String,
        l10n: AppL10n
    ) -> Result<NamingExportBundle, NamingBundleError>? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        return NamingExportBundle.decode(raw, l10n: l10n)
    }

    var body: some View {
        let validation = cachedValidation
        let errorText: String? = {
            if let fileLoadError { return fileLoadError }
            if case .failure(let err) = validation { return err.message }
            return nil
        }()
        let isImportDisabled: Bool = {
            if case .success = validation { return false }
            return true
        }()

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(l10n.tr("导入命名与片名规则", "Import Naming & Title Rules"))
                    .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                    .foregroundStyle(palette.text)
                Spacer()
                SecondaryActionButton(
                    l10n.tr("从文件选择…", "Choose File…"),
                    systemImage: "folder"
                ) {
                    chooseJsonFile()
                }
            }

            Text(
                l10n.tr(
                    "粘贴导出的 JSON 内容，或点击右上角从本地文件读取。确认后会覆盖当前命名规则与片名规则。",
                    "Paste exported JSON below or load from a local file. Importing will overwrite your current naming and title rules."
                )
            )
            .font(.system(size: TidyreelTypeScale.small))
            .foregroundStyle(palette.textMuted)
            .fixedSize(horizontal: false, vertical: true)

            ZStack(alignment: .topLeading) {
                if rawJson.isEmpty {
                    Text("{\n  \"version\": 1,\n  \"naming\": { ... },\n  \"titleRules\": { ... }\n}")
                        .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                        .foregroundStyle(palette.textFaint)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $rawJson)
                    .font(.system(size: TidyreelTypeScale.small, design: .monospaced))
                    .foregroundStyle(palette.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .onChange(of: rawJson) { _, next in
                        fileLoadError = nil
                        cachedValidation = Self.validateJson(next, l10n: l10n)
                    }
            }
            .frame(height: 160)
            .background(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .fill(palette.canvas)
            )
            .overlay(
                RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                    .strokeBorder(palette.lineStrong, lineWidth: hairlineWidth)
            )

            if let errorText {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.danger)
                    Text(errorText)
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(palette.danger.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(palette.danger.opacity(0.35), lineWidth: hairlineWidth)
                )
            } else if case .success(let bundle) = validation {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(palette.success)
                        Text(l10n.tr("校验通过，将应用以下配置", "Valid configuration ready to apply"))
                            .font(.system(size: TidyreelTypeScale.small, weight: .semibold))
                            .foregroundStyle(palette.text)
                    }

                    Text(
                        l10n.tr(
                            "播放器预设：\(bundle.naming?.player.displayName ?? "保持现有")",
                            "Player preset: \(bundle.naming?.player.displayName ?? "Keep current")"
                        )
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.text)

                    if let naming = bundle.naming {
                        let movieCount = naming.movie.rewrites.count
                        let tvCount = naming.tv.rewrites.count
                        Text(
                            l10n.tr(
                                "替换规则：共 \(movieCount + tvCount) 条（电影 \(movieCount) 条 · 剧集 \(tvCount) 条）",
                                "Rewrite rules: \(movieCount + tvCount) total (Movies \(movieCount) · TV \(tvCount))"
                            )
                        )
                        .font(.system(size: TidyreelTypeScale.small))
                        .foregroundStyle(palette.text)
                    }

                    Text(
                        bundle.titleRules != nil
                            ? l10n.tr(
                                "片名规则：清洗 \(bundle.titleRules!.cleanups.count) 条 · 指定匹配 \(bundle.titleRules!.pins.count) 条",
                                "Title rules: \(bundle.titleRules!.cleanups.count) cleanups · \(bundle.titleRules!.pins.count) pinned matches"
                            )
                            : l10n.tr("片名规则：保持现有", "Title rules: Keep current")
                    )
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.text)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(palette.success.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .strokeBorder(palette.success.opacity(0.30), lineWidth: hairlineWidth)
                )
            }

            HStack(spacing: 8) {
                Spacer()
                QuietTextButton(l10n.cancel) {
                    dismiss()
                }
                PrimaryActionButton(
                    l10n.tr("导入并应用", "Import & Apply"),
                    isDisabled: isImportDisabled
                ) {
                    if case .success(let bundle) = validation {
                        if let naming = bundle.naming {
                            store.setNamingProfile(naming)
                        }
                        if let rules = bundle.titleRules {
                            store.setTitleRules(rules)
                        }
                        store.showToast(l10n.tr("已导入命名与片名规则", "Imported naming & title rules"))
                        dismiss()
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 540)
        .background(palette.panel)
        .onChange(of: l10n.isEn) { _, _ in
            cachedValidation = Self.validateJson(rawJson, l10n: l10n)
        }
    }

    private func chooseJsonFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let loaded = try String(contentsOf: url, encoding: .utf8)
            rawJson = loaded
            fileLoadError = nil
            cachedValidation = Self.validateJson(loaded, l10n: l10n)
        } catch {
            fileLoadError = l10n.tr("读取文件失败：\(error.localizedDescription)", "Failed to read file: \(error.localizedDescription)")
        }
    }
}
