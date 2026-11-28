import AppKit
import Foundation
import SwiftUI
import TidyreelDesign
import TidyreelMetadata
import TidyreelModels
import TidyreelServices

private let defaultTmdbBaseURL = "https://api.themoviedb.org/3"

public struct SettingsPageView: View {
    public let store: AppStore

    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    @State private var showApiKey: Bool = false
    @State private var tmdbApiKeyDraft: String
    @State private var tmdbBaseUrlDraft: String
    @State private var tmdbSyncTask: Task<Void, Never>? = nil
    @State private var isTestingConnection: Bool = false
    @State private var testMessage: String? = nil
    @State private var testOk: Bool? = nil
    @State private var isClearingCache: Bool = false
    @State private var isConfirmingClearTasks: Bool = false
    @State private var isLicensesSheetPresented: Bool = false

    public init(store: AppStore) {
        self.store = store
        self._tmdbApiKeyDraft = State(initialValue: store.settings.tmdbApiKey)
        self._tmdbBaseUrlDraft = State(initialValue: store.settings.tmdbBaseUrl)
    }

    private var settings: AppSettings {
        store.settings
    }

    private var hasBuiltInToken: Bool {
        !store.builtInTmdbToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var finishedTasks: [TaskSummary] {
        store.tasks.filter { !$0.stage.isActive }
    }

    public var body: some View {
        PageScaffoldView(
            title: l10n.tr("设置", "Settings"),
            maxWidth: 820
        ) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    tmdbSection
                    organizeSection
                    matchingSection
                    appearanceSection
                    notificationsSection
                    dataSection
                    aboutSection
                }
                .padding(.leading, 48)
                .padding(.trailing, 40)
                .padding(.bottom, 28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(palette.canvas)
        .onChange(of: settings.tmdbApiKey) { _, next in
            if tmdbSyncTask == nil, next != tmdbApiKeyDraft {
                tmdbApiKeyDraft = next
            }
        }
        .onChange(of: settings.tmdbBaseUrl) { _, next in
            if tmdbSyncTask == nil, next != tmdbBaseUrlDraft {
                tmdbBaseUrlDraft = next
            }
        }
        .onDisappear {
            commitPendingTmdbDrafts()
        }
        .sheet(isPresented: $isConfirmingClearTasks) {
            let count = finishedTasks.count
            ConfirmActionSheet(
                title: l10n.tr("清空已完成的任务？", "Clear completed tasks?"),
                message: l10n.tr(
                    "将移除 \(count) 条已结束的任务记录。媒体库中的任何文件都不会被改动，但清空后将无法再对这些任务执行一键撤销。",
                    "Removes \(l10n.plural(count, "completed task")). Your media files stay untouched, but cleared tasks can no longer be undone."
                ),
                confirmLabel: l10n.clear,
                isDestructive: true
            ) {
                let ids = finishedTasks.map(\.id)
                Task { @MainActor in
                    for id in ids {
                        try? await store.taskManager.delete(id)
                    }
                    store.showToast(
                        l10n.tr("已清空已完成任务", "Cleared completed tasks")
                    )
                }
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
        .sheet(isPresented: $isLicensesSheetPresented) {
            OpenSourceLicensesSheet()
                .environment(\.palette, palette)
                .environment(\.l10n, l10n)
        }
    }

    // MARK: - 1. TMDB 元数据 (`TMDB Metadata`)

    private var tmdbSection: some View {
        let trimmedUrl = tmdbBaseUrlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlNonDefault = !trimmedUrl.isEmpty && trimmedUrl != defaultTmdbBaseURL

        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("TMDB 元数据", "TMDB Metadata"))

            PanelBox(padding: EdgeInsets(top: 8, leading: 8, bottom: 10, trailing: 14)) {
                VStack(alignment: .leading, spacing: 4) {
                    FormRow(
                        label: "API Key",
                        labelWidth: 110,
                        help: hasBuiltInToken
                            ? l10n.tr(
                                "已内置默认 key，可以留空；填了就优先用你的",
                                "A default key is built in so you can leave this blank; your own key takes precedence"
                            )
                            : l10n.tr(
                                "支持 v3 key 和 v4 Read Access Token；可在 themoviedb.org → 设置 → API 免费申请",
                                "Supports v3 API key or v4 Read Access Token; free at themoviedb.org → Settings → API"
                            )
                    ) {
                        InkTextField(
                            placeholder: hasBuiltInToken
                                ? l10n.tr("使用内置 key", "Using built-in key")
                                : l10n.tr("粘贴 API Key 或 Read Token", "Paste API key or Read Access Token"),
                            text: Binding(
                                get: { tmdbApiKeyDraft },
                                set: { newVal in
                                    guard newVal != tmdbApiKeyDraft else { return }
                                    tmdbApiKeyDraft = newVal
                                    if testMessage != nil {
                                        testMessage = nil
                                        testOk = nil
                                    }
                                    scheduleTmdbDraftCommit()
                                }
                            ),
                            isSecure: !showApiKey,
                            onSubmit: commitPendingTmdbDrafts
                        ) {
                            Button {
                                showApiKey.toggle()
                            } label: {
                                Image(systemName: showApiKey ? "eye.slash" : "eye")
                                    .font(.system(size: 13))
                                    .foregroundStyle(palette.textMuted)
                                    .frame(width: 22, height: 20)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(showApiKey ? l10n.tr("隐藏", "Hide") : l10n.tr("显示", "Show"))
                        }
                    }

                    FormRow(
                        label: "Base URL",
                        labelWidth: 110,
                        help: l10n.tr(
                            "访问不了 TMDB 时，填一个反向代理地址",
                            "Enter a reverse proxy URL if direct access to TMDB is blocked"
                        )
                    ) {
                        HStack(spacing: 8) {
                            InkTextField(
                                placeholder: defaultTmdbBaseURL,
                                text: Binding(
                                    get: { tmdbBaseUrlDraft },
                                    set: { newUrl in
                                        guard newUrl != tmdbBaseUrlDraft else { return }
                                        tmdbBaseUrlDraft = newUrl
                                        testMessage = nil
                                        testOk = nil
                                        scheduleTmdbDraftCommit()
                                    }
                                ),
                                onSubmit: commitPendingTmdbDrafts
                            )

                            if urlNonDefault {
                                QuietTextButton(l10n.tr("恢复默认", "Reset")) {
                                    testMessage = nil
                                    testOk = nil
                                    tmdbBaseUrlDraft = defaultTmdbBaseURL
                                    commitPendingTmdbDrafts()
                                }
                            }
                        }
                    }

                    FormRow(
                        label: "",
                        labelWidth: 110
                    ) {
                        VStack(alignment: .leading, spacing: 6) {
                            if isTestingConnection {
                                HStack(spacing: 6) {
                                    DashedSpinner(size: 14, color: palette.textFaint)
                                    Text(l10n.tr("测试中…", "Testing…"))
                                        .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                                        .foregroundStyle(palette.textFaint)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .frame(minHeight: 30)
                                .overlay(
                                    RoundedRectangle(cornerRadius: TidyreelRadii.lg, style: .continuous)
                                        .strokeBorder(palette.line, lineWidth: hairlineWidth)
                                )
                            } else {
                                SecondaryActionButton(
                                    l10n.tr("测试连接", "Test Connection"),
                                    systemImage: "bolt.horizontal"
                                ) {
                                    testTmdbConnection()
                                }
                            }

                            if let testMessage {
                                Text(testMessage)
                                    .font(.system(size: TidyreelTypeScale.small))
                                    .foregroundStyle(testOk == true ? palette.success : palette.danger)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 2. 整理 (`Organize`)

    private var organizeSection: some View {
        let concurrencySelection = [1, 2, 4, 8].contains(settings.concurrency) ? settings.concurrency : 4
        let rpsSelection = [2, 5, 10].contains(settings.requestsPerSecond) ? settings.requestsPerSecond : 5

        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("整理", "Organize"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("默认整理模式", "Default Organize Mode"),
                        caption: l10n.tr(
                            "确认识别结果时还能改",
                            "You can still change this while reviewing matches"
                        )
                    ) {
                        SlidingSegmented(
                            options: [
                                (OrganizeMode.inPlace, l10n.organizeModeLabel(.inPlace)),
                                (OrganizeMode.moveToLibrary, l10n.organizeModeLabel(.moveToLibrary)),
                            ],
                            selection: settings.defaultMode
                        ) { mode in
                            store.updateSettings { $0.defaultMode = mode }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("自动删除垃圾文件", "Auto-select Junk for Deletion"),
                        caption: l10n.tr(
                            "广告等垃圾文件默认勾选删除，删除前会再问一次",
                            "Pre-select ad and junk files for removal; you will still be asked before deleting"
                        )
                    ) {
                        InkSwitch(isOn: settings.autoDeleteJunk) { val in
                            store.updateSettings { $0.autoDeleteJunk = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("识别前预览", "Scan Preview"),
                        caption: l10n.tr(
                            "先快速扫一遍文件数量和可能的问题，再决定是否开始",
                            "Quickly inspect file counts and potential issues before starting matching"
                        )
                    ) {
                        InkSwitch(isOn: settings.scanPreview) { val in
                            store.updateSettings { $0.scanPreview = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("刮削时覆盖已有 NFO", "Overwrite Existing NFO"),
                        caption: l10n.tr(
                            "默认保留已存在的 .nfo 文件；开启后重新刮削会安全替换为最新完整元数据",
                            "Keep existing .nfo files by default; enable to safely replace them with fresh metadata when scraping"
                        )
                    ) {
                        InkSwitch(isOn: settings.overwriteNfo) { val in
                            store.updateSettings { $0.overwriteNfo = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("同时处理的文件数", "Concurrent Operations"),
                        caption: l10n.tr(
                            "越大越快，但网盘更容易限流。修改后对新任务立即生效",
                            "Higher is faster but more likely to trigger rate limits. Applies immediately to new runs"
                        )
                    ) {
                        SlidingSegmented(
                            options: [
                                (1, "1"),
                                (2, "2"),
                                (4, "4"),
                                (8, "8"),
                            ],
                            selection: concurrencySelection
                        ) { val in
                            store.updateSettings { $0.concurrency = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("每秒请求上限", "Max Requests / Sec"),
                        caption: l10n.tr(
                            "仅影响网盘/远程连接。Alist 默认会限流，频繁报错时调小。修改后立即生效",
                            "Applies to remote connections only. Lower this if Alist rate-limits you. Takes effect immediately"
                        )
                    ) {
                        SlidingSegmented(
                            options: [
                                (2, "2"),
                                (5, "5"),
                                (10, "10"),
                            ],
                            selection: rpsSelection
                        ) { val in
                            store.updateSettings { $0.requestsPerSecond = val }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 3. 识别 (`Matching`)

    private var matchingSection: some View {
        let langSelection = ["zh-CN", "zh-TW", "en-US"].contains(settings.tmdbLanguage)
            ? settings.tmdbLanguage
            : "zh-CN"
        let thresholdSelection: Int = {
            if abs(settings.confidenceThreshold - 0.60) < 0.02 { return 60 }
            if abs(settings.confidenceThreshold - 0.85) < 0.02 { return 85 }
            return 70
        }()

        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("识别", "Matching"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("内容类型", "Content Hint"),
                        caption: l10n.tr(
                            "混合：按文件名逐个判断；动漫会用罗马音查别名、优先日本作品；选电视剧或电影则全部按该类型识别",
                            "Mixed detects per file; Anime looks up romanized aliases and prefers Japanese titles; TV or Movies forces that type"
                        )
                    ) {
                        SlidingSegmented(
                            options: MediaHint.allCases.map { ($0, l10n.mediaHintLabel($0)) },
                            selection: settings.mediaHint
                        ) { hint in
                            store.updateSettings { $0.mediaHint = hint }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("TMDB 语言", "TMDB Language"),
                        caption: l10n.tr(
                            "片名、简介和集标题用哪种语言，找不到时退回英文",
                            "Language for titles, overviews, and episode names; falls back to English if unavailable"
                        )
                    ) {
                        SlidingSegmented(
                            options: [
                                ("zh-CN", l10n.tr("简体", "zh-CN")),
                                ("zh-TW", l10n.tr("繁体", "zh-TW")),
                                ("en-US", "English"),
                            ],
                            selection: langSelection
                        ) { lang in
                            store.updateSettings { $0.tmdbLanguage = lang }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("「有把握」的标准", "Confidence Threshold"),
                        caption: l10n.tr(
                            "任务页「只整理有把握的」按这个标准挑选作品",
                            "Used by \"Organize confident only\" on the Tasks page"
                        )
                    ) {
                        SlidingSegmented(
                            options: [
                                (60, l10n.tr("宽松", "Relaxed")),
                                (70, l10n.tr("标准", "Standard")),
                                (85, l10n.tr("严格", "Strict")),
                            ],
                            selection: thresholdSelection
                        ) { bucket in
                            let val: Double
                            switch bucket {
                            case 60: val = 0.6
                            case 85: val = 0.85
                            default: val = 0.7
                            }
                            store.updateSettings { $0.confidenceThreshold = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("媒体头探测", "Container Media Probe"),
                        caption: l10n.tr(
                            "仅读取 MKV/MP4 文件头（不下载整片），自动补全分辨率、杜比视界/HDR 与音轨信息",
                            "Reads only MKV/MP4 headers (never whole files) to fill in resolution, Dolby Vision/HDR, and audio tracks"
                        )
                    ) {
                        InkSwitch(isOn: settings.probeMedia) { val in
                            store.updateSettings { $0.probeMedia = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("Bangumi 动漫译名", "Bangumi Anime Aliases"),
                        caption: l10n.tr(
                            "结合 Bangumi 与 AniList 补全番剧中文译名和日文原名，提高动漫匹配率",
                            "Use Bangumi alongside AniList to improve anime alias matching"
                        )
                    ) {
                        InkSwitch(isOn: settings.enableBangumi) { val in
                            store.updateSettings { $0.enableBangumi = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("清除 TMDB 缓存", "Clear TMDB Cache"),
                        caption: l10n.tr(
                            "清除元数据和海报缓存，TMDB 上刚更新的信息没显示出来时用",
                            "Clear cached metadata and posters when recent TMDB updates are not showing up"
                        )
                    ) {
                        SecondaryActionButton(
                            l10n.tr("清除", "Clear"),
                            isDisabled: isClearingCache
                        ) {
                            isClearingCache = true
                            Task { @MainActor in
                                await store.clearCaches()
                                isClearingCache = false
                                store.showToast(l10n.tr("已清除 TMDB 缓存", "TMDB cache cleared"))
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 4. 外观 (`Appearance`)

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("外观", "Appearance"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("语言", "Language"),
                        caption: l10n.tr(
                            "默认在安装时跟随系统语言，可随时切换",
                            "Follows your system language by default; switch anytime"
                        )
                    ) {
                        SlidingSegmented(
                            options: [
                                (AppLanguage.system, l10n.tr("跟随系统", "System")),
                                (AppLanguage.zh, "中文"),
                                (AppLanguage.en, "English"),
                            ],
                            selection: settings.appLanguage
                        ) { lang in
                            store.updateSettings { $0.appLanguage = lang }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("主题", "Theme")
                    ) {
                        SlidingSegmented(
                            options: [
                                (AppThemeMode.light, l10n.tr("浅色", "Light")),
                                (AppThemeMode.dark, l10n.tr("深色", "Dark")),
                                (AppThemeMode.system, l10n.tr("跟随系统", "System")),
                            ],
                            selection: settings.themeMode
                        ) { mode in
                            store.updateSettings { $0.themeMode = mode }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("强调色", "Accent Color")
                    ) {
                        HStack(spacing: 8) {
                            ForEach(AccentChoice.allCases, id: \.self) { choice in
                                AccentCircleSwatch(
                                    choice: choice,
                                    isSelected: settings.accent == choice
                                ) {
                                    store.updateSettings { $0.accent = choice }
                                }
                            }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("启动时收起侧栏", "Collapse Sidebar on Launch")
                    ) {
                        InkSwitch(isOn: settings.sidebarCollapsed) { val in
                            store.updateSettings { $0.sidebarCollapsed = val }
                            store.isSidebarCollapsed = val
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("减少动画", "Reduce Motion"),
                        caption: l10n.tr(
                            "关闭页面切换和列表浮现动画",
                            "Disable page transition and list reveal animations"
                        )
                    ) {
                        InkSwitch(isOn: settings.reduceMotion) { val in
                            store.updateSettings { $0.reduceMotion = val }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 5. 通知 (`Notifications`)

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("通知", "Notifications"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("识别完成时提示", "Notify When Matching Finishes"),
                        caption: l10n.tr(
                            "通过应用内底部提示条提醒",
                            "Show an in-app banner at the bottom"
                        )
                    ) {
                        InkSwitch(isOn: settings.notifyRecognized) { val in
                            store.updateSettings { $0.notifyRecognized = val }
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("整理完成时提示", "Notify When Organizing Finishes"),
                        caption: l10n.tr(
                            "通过应用内底部提示条提醒",
                            "Show an in-app banner at the bottom"
                        )
                    ) {
                        InkSwitch(isOn: settings.notifyFinished) { val in
                            store.updateSettings { $0.notifyFinished = val }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 6. 数据 (`Data`)

    private var dataSection: some View {
        let finished = finishedTasks
        return VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("数据", "Data"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    SettingRow(
                        title: l10n.tr("清空已完成的任务", "Clear Completed Tasks"),
                        caption: finished.isEmpty
                            ? l10n.tr("没有已完成的任务", "No completed tasks")
                            : l10n.tr(
                                "共 \(finished.count) 条。不会动文件，但清空后就不能再撤销",
                                "\(l10n.plural(finished.count, "task")). Your files stay untouched, but cleared tasks can no longer be undone"
                            )
                    ) {
                        SecondaryActionButton(
                            l10n.clear,
                            isDestructive: true,
                            isDisabled: finished.isEmpty
                        ) {
                            isConfirmingClearTasks = true
                        }
                    }

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("数据目录", "Data Directory"),
                        caption: l10n.tr(
                            "设置、连接、任务记录和撤销日志都保存在这里（含敏感凭据 secrets.json，备份/分享前请注意）",
                            "Stores settings, connections, task history, and undo logs (includes sensitive credentials in secrets.json)"
                        )
                    ) {
                        SecondaryActionButton(
                            l10n.tr("在 Finder 中打开", "Show in Finder")
                        ) {
                            openApplicationDataDirectoryInFinder()
                        }
                    }
                }
            }
        }
    }

    // MARK: - 7. 关于 (`About`)

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeaderLabel(l10n.tr("关于", "About"))

            PanelBox(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        AppLogoView(size: 40)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(l10n.appTitle)
                                .font(.system(size: TidyreelTypeScale.body, weight: .semibold))
                                .foregroundStyle(palette.text)

                            Text(l10n.tr("版本 \(AppStore.appVersion)", "Version \(AppStore.appVersion)"))
                                .font(.system(size: 12))
                                .foregroundStyle(palette.textMuted)
                        }

                        Spacer()
                    }
                    .padding(14)

                    SettingsDivider()

                    SettingRow(
                        title: l10n.tr("基于 mnamer (MIT) 的思路", "Inspired by mnamer (MIT)"),
                        caption: l10n.tr(
                            "影视元数据来自 TMDB，本产品使用 TMDB API 但未获得其认可或认证",
                            "Metadata provided by TMDB. This product uses the TMDB API but is not endorsed or certified by TMDB"
                        )
                    ) {
                        QuietTextButton(l10n.tr("查看许可", "Licenses")) {
                            isLicensesSheetPresented = true
                        }
                    }
                }
            }
        }
    }

    // MARK: - Debounced TMDB Draft Persistence

    private func scheduleTmdbDraftCommit() {
        tmdbSyncTask?.cancel()
        let keyDraft = tmdbApiKeyDraft
        let urlDraft = tmdbBaseUrlDraft
        tmdbSyncTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            commitTmdbDrafts(apiKey: keyDraft, baseUrl: urlDraft)
            tmdbSyncTask = nil
        }
    }

    private func commitPendingTmdbDrafts() {
        tmdbSyncTask?.cancel()
        tmdbSyncTask = nil
        commitTmdbDrafts(apiKey: tmdbApiKeyDraft, baseUrl: tmdbBaseUrlDraft)
    }

    private func commitTmdbDrafts(apiKey: String, baseUrl: String) {
        let needsKey = store.settings.tmdbApiKey != apiKey
        let needsUrl = store.settings.tmdbBaseUrl != baseUrl
        guard needsKey || needsUrl else { return }
        store.updateSettings { s in
            if needsKey { s.tmdbApiKey = apiKey }
            if needsUrl { s.tmdbBaseUrl = baseUrl }
        }
    }

    // MARK: - Live Uncached TMDB Connection Test & Finder Helper

    private func testTmdbConnection() {
        guard !isTestingConnection else { return }
        commitPendingTmdbDrafts()
        let customKey = settings.tmdbApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let builtInKey = store.builtInTmdbToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = customKey.isEmpty ? builtInKey : customKey

        if effectiveKey.isEmpty && !store.isDemoMode {
            testOk = false
            testMessage = l10n.tr("请先填写 TMDB API Key", "Please enter a TMDB API key first")
            return
        }

        let keySource = !customKey.isEmpty
            ? l10n.tr("自定义 key", "custom key")
            : l10n.tr("内置 key", "built-in key")

        isTestingConnection = true
        testMessage = nil
        testOk = nil

        let rawUrl = settings.tmdbBaseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseUrl = rawUrl.isEmpty ? defaultTmdbBaseURL : rawUrl
        let language = settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        let isDemo = store.isDemoMode

        Task { @MainActor in
            defer { isTestingConnection = false }
            do {
                let hits: [Candidate]
                if isDemo {
                    hits = try await store.currentMetadataProvider().search("Inception")
                } else {
                    // Bypass SQLiteTmdbCache so invalid keys or broken reverse proxies never pass via cached results.
                    let uncachedProvider = TmdbProvider(
                        config: TmdbConfig(
                            apiKey: effectiveKey,
                            baseUrl: baseUrl,
                            language: language,
                            fallbackLanguage: language == "en-US" ? "zh-CN" : "en-US"
                        ),
                        cache: nil
                    )
                    defer {
                        Task { await uncachedProvider.close() }
                    }
                    hits = try await uncachedProvider.search("Inception")
                }

                let t = store.l10n
                if let first = hits.first {
                    testOk = true
                    testMessage = t.tr(
                        "连接成功：找到「\(first.title)」（使用\(keySource)）",
                        "Connected: found \"\(first.title)\" (using \(keySource))"
                    )
                } else {
                    testOk = false
                    testMessage = t.tr(
                        "已连接（\(keySource)），但没有搜到结果",
                        "Connected (\(keySource)), but no results found"
                    )
                }
            } catch {
                let t = store.l10n
                let rawMsg = (error as? TmdbError)?.message ?? error.localizedDescription
                testOk = false
                testMessage = t.tr(
                    "连接失败（使用\(keySource)）：\(rawMsg)",
                    "Connection failed (using \(keySource)): \(t.coreMessage(rawMsg))"
                )
            }
        }
    }

    private func openApplicationDataDirectoryInFinder() {
        let fm = FileManager.default
        let baseSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundleId = "app.tidyreel.tidyreel"
        let dirURL = baseSupport.lastPathComponent == bundleId
            ? baseSupport
            : baseSupport.appendingPathComponent(bundleId, isDirectory: true)

        try? fm.createDirectory(at: dirURL, withIntermediateDirectories: true)
        if !NSWorkspace.shared.open(dirURL) {
            store.showToast(
                l10n.tr("无法打开目录：\(dirURL.path)", "Unable to open folder: \(dirURL.path)")
            )
        }
    }
}

// MARK: - 22×22 Traditional Chinese Color Circle Swatch (`settings_page.dart:525`)

private struct AccentCircleSwatch: View {
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n
    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let hex = palette.isDark ? choice.darkHex : choice.lightHex
        let swatchColor = TidyreelPalette.color(argb: hex)
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let checkColor: Color = luminance > 0.50 ? .black : .white

        Button(action: action) {
            ZStack {
                Circle()
                    .fill(swatchColor)

                if isSelected {
                    Circle()
                        .strokeBorder(palette.text, lineWidth: 2)

                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(checkColor)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(choice.localizedLabel(l10n))
    }
}

// MARK: - Open Source Licenses Sheet (`settings_page.dart:708`)

private struct OpenSourceLicensesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(l10n.tr("开源许可", "Open Source Licenses"))
                .font(.system(size: TidyreelTypeScale.headline, weight: .semibold))
                .foregroundStyle(palette.text)

            Text(
                l10n.tr(
                    """
                    命名与解析思路参考 mnamer（MIT License）。
                    原版权声明见项目 LICENSES/mnamer-MIT.txt。

                    影视、分集与演职员元数据来自 TMDB（The Movie Database），动漫译名与罗马音别名辅以 Bangumi 番组计划与 AniList API。
                    macOS 原生版使用 Apple Foundation、SwiftUI、SQLite3 与 NetFS 框架构建。
                    """,
                    """
                    Naming and parsing design inspired by mnamer (MIT License).
                    See LICENSES/mnamer-MIT.txt for the original notice.

                    Movie, series, and cast metadata provided by TMDB (The Movie Database), with anime alias support from Bangumi and AniList.
                    Built natively for macOS with Apple Foundation, SwiftUI, SQLite3, and NetFS.
                    """
                )
            )
            .font(.system(size: TidyreelTypeScale.body))
            .foregroundStyle(palette.textMuted)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                SecondaryActionButton(l10n.close) {
                    dismiss()
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: 480)
        .background(palette.panel)
    }
}
