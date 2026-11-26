import AppKit
import SwiftUI
import TidyreelDesign
import TidyreelModels
import TidyreelServices
import TidyreelStorage

struct ConnectionEditorSheet: View {
    let store: AppStore
    let existing: ConnectionConfig?
    let isCopy: Bool
    var onSavedNewConnection: ((ConnectionConfig) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @Environment(\.l10n) private var l10n

    private enum DavPreset: String, CaseIterable, Identifiable {
        case alistApi
        case alistDav
        case synology
        case generic

        var id: String { rawValue }

        var connectionType: ConnectionType {
            switch self {
            case .alistApi: return .alist
            case .alistDav, .synology, .generic: return .webdav
            }
        }

        var defaultPort: String {
            switch self {
            case .alistApi, .alistDav: return "5244"
            case .synology: return "5005"
            case .generic: return ""
            }
        }

        var defaultPath: String {
            switch self {
            case .alistDav: return "/dav"
            case .alistApi, .synology, .generic: return ""
            }
        }

        func localizedLabel(_ l10n: AppL10n) -> String {
            switch self {
            case .alistApi:
                return l10n.tr("Alist / OpenList（API，推荐）", "Alist / OpenList (API, Recommended)")
            case .alistDav:
                return l10n.tr("Alist / OpenList（WebDAV /dav）", "Alist / OpenList (WebDAV /dav)")
            case .synology:
                return l10n.tr("群晖 WebDAV", "Synology WebDAV")
            case .generic:
                return l10n.tr("通用 WebDAV", "Generic WebDAV")
            }
        }
    }

    private struct DirPasswordRowItem: Identifiable, Equatable {
        let id = UUID()
        var path: String
        var password: String
        var isRevealed: Bool = false
    }

    private enum PickerTarget: Identifiable {
        case startDir
        case libraryRoot
        case dirPassword(UUID)

        var id: String {
            switch self {
            case .startDir: return "startDir"
            case .libraryRoot: return "libraryRoot"
            case .dirPassword(let uuid): return "dirPw-\(uuid.uuidString)"
            }
        }
    }

    private struct FolderPickerSession: Identifiable {
        let id = UUID()
        let target: PickerTarget
        let title: String
        let initialPath: String
        let backend: any StorageBackend
    }

    private struct TestOutcome: Equatable {
        var isSuccess: Bool
        var isAuthFailure: Bool
        var message: String
    }

    @State private var type: ConnectionType
    @State private var name: String
    @State private var scheme: String
    @State private var host: String
    @State private var port: String
    @State private var davPath: String
    @State private var smbShare: String
    @State private var localFolder: String
    @State private var username: String
    @State private var password: String
    @State private var showPassword: Bool = false
    @State private var startDir: String
    @State private var libraryRoot: String
    @State private var dirPasswords: [DirPasswordRowItem]
    @State private var dirPasswordsExpanded: Bool

    @State private var showValidationErrors: Bool = false
    @State private var browseValidationHint: String?
    @State private var isTesting: Bool = false
    @State private var testTask: Task<Void, Never>?
    @State private var testOutcome: TestOutcome?
    @State private var activeFolderPicker: FolderPickerSession?
    @State private var pickerBackendToClose: (any StorageBackend)?

    init(
        store: AppStore,
        existing: ConnectionConfig? = nil,
        isCopy: Bool = false,
        onSavedNewConnection: ((ConnectionConfig) -> Void)? = nil
    ) {
        self.store = store
        self.existing = existing
        self.isCopy = isCopy
        self.onSavedNewConnection = onSavedNewConnection

        let initType = existing?.type ?? .alist
        let savedPw = existing.map { store.readConnectionPassword($0.id) } ?? ""
        let savedDirPws = existing.map { store.readConnectionDirPasswords($0.id) } ?? [:]

        let parsedSmb = (existing?.type == .smb) ? parseSmbEndpoint(existing?.endpoint ?? "") : nil
        let parsedEndpoint: EndpointParts = {
            guard let existing else { return EndpointParts(port: "5244") }
            switch existing.type {
            case .local:
                return EndpointParts(port: "5244")
            case .smb:
                return EndpointParts.parse(parsedSmb?.host ?? "")
            case .alist, .webdav:
                return EndpointParts.parse(existing.endpoint)
            }
        }()

        let smbShareInit: String = {
            guard let parsedSmb else { return "" }
            if parsedSmb.base.isEmpty { return parsedSmb.share }
            return "\(parsedSmb.share)/\(parsedSmb.base)"
        }()

        let dirPwRows = savedDirPws.keys.sorted().map { key in
            DirPasswordRowItem(path: key, password: savedDirPws[key] ?? "")
        }

        self._type = State(initialValue: initType)
        self._name = State(initialValue: isCopy ? "" : (existing?.name ?? ""))
        self._scheme = State(initialValue: parsedEndpoint.scheme)
        self._host = State(initialValue: parsedEndpoint.host)
        self._port = State(initialValue: parsedEndpoint.port)
        self._davPath = State(
            initialValue: (existing == nil && initType == .webdav) ? "/dav" : parsedEndpoint.path
        )
        self._smbShare = State(initialValue: smbShareInit)
        self._localFolder = State(initialValue: existing?.type == .local ? (existing?.endpoint ?? "") : "")
        self._username = State(initialValue: existing?.username ?? (existing == nil ? "admin" : ""))
        self._password = State(initialValue: savedPw)
        self._startDir = State(
            initialValue: (existing?.startDir == "/" || existing == nil) ? "" : (existing?.startDir ?? "")
        )
        self._libraryRoot = State(initialValue: existing?.libraryRoot ?? "")
        self._dirPasswords = State(initialValue: dirPwRows)
        self._dirPasswordsExpanded = State(initialValue: !dirPwRows.isEmpty)
    }

    private var currentPreset: DavPreset {
        if type == .alist { return .alistApi }
        let trimmedPath = davPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedPath == "/dav" { return .alistDav }
        if trimmedPort == "5005" || trimmedPort == "5006" { return .synology }
        return .generic
    }

    private var composedEndpoint: String {
        switch type {
        case .local:
            return localFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        case .smb:
            let (hostPart, p) = EndpointParts.formatHostAndPort(rawHost: host, rawPort: port)
            let shareSegs = smbShare
                .components(separatedBy: CharacterSet(charactersIn: "/\\"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            let portPart = (p.isEmpty || p == "445") ? "" : ":\(p)"
            return "smb://\(hostPart)\(portPart)/\(shareSegs)"
        case .alist, .webdav:
            return EndpointParts(
                scheme: scheme,
                host: host,
                port: port,
                path: type == .webdav ? davPath : ""
            ).compose()
        }
    }

    private var portErrorMessage: String? {
        let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let n = Int(trimmed), (1...65535).contains(n) else {
            return l10n.tr("端口应为 1–65535", "Port must be 1–65535")
        }
        return nil
    }

    private var isFormValid: Bool {
        if type == .local {
            return !localFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        if portErrorMessage != nil { return false }
        if type == .smb && smbShare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        guard let comps = URLComponents(string: composedEndpoint),
              let parsedHost = comps.host,
              !parsedHost.isEmpty else {
            return false
        }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Sheet Header & Type Picker
            VStack(alignment: .leading, spacing: 12) {
                Text(
                    existing == nil || isCopy
                        ? l10n.tr("添加连接", "Add Connection")
                        : l10n.tr("编辑连接", "Edit Connection")
                )
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(palette.text)

                SlidingSegmented(
                    options: [
                        (value: ConnectionType.alist, label: "Alist"),
                        (value: ConnectionType.webdav, label: "WebDAV"),
                        (value: ConnectionType.smb, label: "SMB"),
                        (value: ConnectionType.local, label: l10n.connectionTypeLabel(.local)),
                    ],
                    selection: type,
                    onSelect: { nextType in
                        switchConnectionType(to: nextType)
                    }
                )
                .frame(maxWidth: .infinity)

                Text(typeSubtitle)
                    .font(.system(size: TidyreelTypeScale.small))
                    .foregroundStyle(palette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider().overlay(palette.line)

            // Form Body
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 13) {
                    formRow(label: l10n.tr("名称", "Name")) {
                        TextField(
                            l10n.tr("留空时自动用文件夹或主机名", "Auto-filled from folder or host if blank"),
                            text: $name
                        )
                        .textFieldStyle(.roundedBorder)
                    }

                    if type == .local {
                        localFolderSection
                    } else {
                        remoteServerSection
                    }

                    Divider()
                        .overlay(palette.line)
                        .padding(.vertical, 4)

                    pathsSection

                    if let browseValidationHint {
                        Text(browseValidationHint)
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.warning)
                            .padding(.leading, 96)
                    }

                    if let outcome = testOutcome {
                        testOutcomeBanner(outcome)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
            }

            Divider().overlay(palette.line)

            // Footer Actions
            HStack(spacing: 10) {
                SecondaryActionButton(
                    isTesting
                        ? l10n.tr("正在测试…", "Testing…")
                        : l10n.tr("测试连接", "Test Connection"),
                    systemImage: "bolt.horizontal",
                    isDisabled: isTesting
                ) {
                    runConnectionTest()
                }

                if isTesting {
                    DashedSpinner(size: 14)
                }

                Spacer()

                QuietTextButton(l10n.cancel) {
                    testTask?.cancel()
                    dismiss()
                }

                PrimaryActionButton(l10n.tr("保存", "Save")) {
                    saveConnection()
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .frame(width: 560)
        .frame(minHeight: 480, maxHeight: 680)
        .background(palette.canvas)
        .onChange(of: host) { _, newValue in
            invalidateTest()
            handlePastedHostIfNeeded(newValue)
        }
        .onChange(of: port) { _, _ in invalidateTest() }
        .onChange(of: scheme) { _, _ in invalidateTest() }
        .onChange(of: davPath) { _, _ in invalidateTest() }
        .onChange(of: smbShare) { _, _ in invalidateTest() }
        .onChange(of: localFolder) { _, _ in invalidateTest() }
        .onChange(of: username) { _, _ in invalidateTest() }
        .onChange(of: password) { _, _ in invalidateTest() }
        .onChange(of: startDir) { _, _ in invalidateTest() }
        .onChange(of: libraryRoot) { _, _ in invalidateTest() }
        .onDisappear {
            testTask?.cancel()
            closePickerBackendIfNeeded()
        }
        .sheet(
            item: $activeFolderPicker,
            onDismiss: {
                closePickerBackendIfNeeded()
            }
        ) { session in
            RemoteFolderPickerSheet(
                title: session.title,
                initialPath: session.initialPath,
                backend: session.backend,
                shouldCloseBackendOnDisappear: false
            ) { chosen in
                applyPickedFolder(chosen, to: session.target)
            }
            .environment(\.palette, palette)
            .environment(\.l10n, l10n)
        }
    }

    // MARK: - Subsections

    private var typeSubtitle: String {
        switch type {
        case .alist:
            return l10n.tr(
                "通过 Alist / OpenList 的 API 连接，批量改名更快",
                "Connect via the Alist / OpenList API for faster batch renames"
            )
        case .webdav:
            return l10n.tr(
                "通用 WebDAV：Alist、OpenList、群晖、Nextcloud 等",
                "Standard WebDAV: Alist, OpenList, Synology, Nextcloud, etc."
            )
        case .smb:
            return l10n.tr(
                "局域网共享文件夹：NAS、路由器、Windows 共享",
                "Network share: NAS, router, or Windows SMB folder"
            )
        case .local:
            return l10n.tr(
                "直接整理这台电脑上的文件夹",
                "Organize folders directly on this computer"
            )
        }
    }

    private var localFolderSection: some View {
        formRow(
            label: l10n.tr("本地文件夹", "Folder"),
            error: showValidationErrors && localFolder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? l10n.tr("请选择或填写本地文件夹路径", "Please choose or enter a local folder path")
                : nil
        ) {
            HStack(spacing: 8) {
                TextField("/Users/me/Downloads", text: $localFolder)
                    .textFieldStyle(.roundedBorder)

                SecondaryActionButton(l10n.tr("选择…", "Choose…"), systemImage: "folder") {
                    chooseLocalFolderWithOpenPanel()
                }
            }
        }
    }

    private var remoteServerSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            if type == .alist || type == .webdav {
                formRow(label: l10n.tr("模板", "Preset")) {
                    Menu {
                        ForEach(DavPreset.allCases) { preset in
                            Button(preset.localizedLabel(l10n)) {
                                applyPreset(preset)
                            }
                        }
                    } label: {
                        HStack {
                            Text(currentPreset.localizedLabel(l10n))
                                .font(.system(size: TidyreelTypeScale.body))
                            Spacer()
                        }
                    }
                    .frame(maxWidth: 320)
                }
            }

            formRow(
                label: l10n.tr("服务器", "Server"),
                help: serverHelpText,
                error: serverValidationError
            ) {
                HStack(spacing: 6) {
                    if type != .smb {
                        Picker("", selection: $scheme) {
                            Text("http://").tag("http")
                            Text("https://").tag("https")
                        }
                        .labelsHidden()
                        .frame(width: 92)
                    }

                    TextField(
                        l10n.tr("主机名或 IP，如 192.168.1.10", "Host or IP, e.g. 192.168.1.10"),
                        text: $host
                    )
                    .textFieldStyle(.roundedBorder)

                    Text(":")
                        .foregroundStyle(palette.textFaint)

                    TextField(type == .smb ? "445" : "5244", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 72)
                }
            }

            if type == .smb {
                formRow(
                    label: l10n.tr("共享名", "Share"),
                    help: l10n.tr(
                        "比如 影视、video；也可以写到子文件夹，如 影视/下载",
                        "e.g. media or video; subfolders like media/downloads also work"
                    ),
                    error: showValidationErrors && smbShare.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? l10n.tr("请填写共享名", "Share name is required")
                        : nil
                ) {
                    TextField(l10n.tr("影视", "media"), text: $smbShare)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if type == .webdav {
                formRow(
                    label: l10n.tr("路径", "Path"),
                    help: l10n.tr(
                        "Alist / OpenList 填 /dav；其他 WebDAV 服务按实际路径填写，可以留空",
                        "Use /dav for Alist / OpenList, or your server WebDAV mount path (optional)"
                    )
                ) {
                    TextField("/dav", text: $davPath)
                        .textFieldStyle(.roundedBorder)
                }
            }

            // Endpoint live preview
            formRow(label: "") {
                HStack(spacing: 6) {
                    Image(systemName: "link")
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textFaint)
                    Text(
                        host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? l10n.tr("填写主机后显示完整地址", "Full address appears once host is entered")
                            : composedEndpoint
                    )
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(palette.textMuted)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                        .fill(palette.hover)
                )
            }

            formRow(
                label: l10n.tr("用户名", "Username"),
                help: l10n.tr("区分大小写", "Case-sensitive")
            ) {
                TextField("admin", text: $username)
                    .textFieldStyle(.roundedBorder)
            }

            formRow(
                label: l10n.tr("密码", "Password"),
                help: l10n.tr("只保存在这台电脑上", "Stored locally on this computer only")
            ) {
                HStack(spacing: 6) {
                    Group {
                        if showPassword {
                            TextField("", text: $password)
                        } else {
                            SecureField("", text: $password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .font(.system(size: 12.5))
                            .foregroundStyle(palette.textMuted)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showPassword ? l10n.tr("隐藏密码", "Hide password") : l10n.tr("显示密码", "Show password"))
                }
            }

            if type == .alist {
                dirPasswordsSection
            }
        }
    }

    private var dirPasswordsSection: some View {
        formRow(
            label: l10n.tr("目录密码", "Folder Passwords"),
            help: l10n.tr(
                "仅 Alist / OpenList 加密目录需要，填写目录路径（如 /私密）与访问密码",
                "Only needed for password-protected Alist / OpenList folders (e.g. /private)"
            )
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        dirPasswordsExpanded.toggle()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: dirPasswordsExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(palette.textMuted)
                            Text(
                                dirPasswords.isEmpty
                                    ? l10n.tr("目录密码（可选）", "Folder passwords (optional)")
                                    : l10n.tr("目录密码（已设 \(dirPasswords.count) 条）", "Folder passwords (\(dirPasswords.count))")
                            )
                            .font(.system(size: TidyreelTypeScale.small))
                            .foregroundStyle(palette.textMuted)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        dirPasswords.append(DirPasswordRowItem(path: "", password: ""))
                        dirPasswordsExpanded = true
                        invalidateTest()
                    } label: {
                        Label(l10n.tr("添加目录密码", "Add Password"), systemImage: "plus")
                            .font(.system(size: TidyreelTypeScale.small, weight: .medium))
                            .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                }

                if dirPasswordsExpanded && !dirPasswords.isEmpty {
                    VStack(spacing: 6) {
                        ForEach($dirPasswords) { $item in
                            let rowId = item.id
                            HStack(spacing: 6) {
                                TextField(l10n.tr("/私密", "/private"), text: $item.path)
                                    .textFieldStyle(.roundedBorder)
                                    .onChange(of: item.path) { _, _ in invalidateTest() }

                                Button {
                                    openRemotePicker(.dirPassword(rowId))
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.system(size: 12))
                                        .foregroundStyle(palette.textMuted)
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .help(l10n.tr("浏览远程目录", "Browse remote folder"))

                                Group {
                                    if item.isRevealed {
                                        TextField(l10n.tr("密码", "Password"), text: $item.password)
                                    } else {
                                        SecureField(l10n.tr("密码", "Password"), text: $item.password)
                                    }
                                }
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: item.password) { _, _ in invalidateTest() }

                                Button {
                                    item.isRevealed.toggle()
                                } label: {
                                    Image(systemName: item.isRevealed ? "eye.slash" : "eye")
                                        .font(.system(size: 12))
                                        .foregroundStyle(palette.textMuted)
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    dirPasswords.removeAll { $0.id == rowId }
                                    invalidateTest()
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(palette.textMuted)
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private var pathsSection: some View {
        VStack(alignment: .leading, spacing: 13) {
            if type != .local {
                formRow(
                    label: l10n.tr("连接路径", "Start Path"),
                    help: l10n.tr(
                        "只能访问这个路径及以下，比如 /PC；留空可访问全部",
                        "Restrict browsing to this folder and below (e.g. /PC); leave blank for root"
                    )
                ) {
                    HStack(spacing: 6) {
                        TextField("/", text: $startDir)
                            .textFieldStyle(.roundedBorder)

                        SecondaryActionButton(l10n.tr("浏览…", "Browse…")) {
                            openRemotePicker(.startDir)
                        }
                    }
                }
            }

            formRow(
                label: l10n.tr("媒体库", "Media Library"),
                help: type == .local
                    ? l10n.tr(
                        "「移动到媒体库」模式下，整理好的文件放到这里（相对于上方本地文件夹，可选）",
                        "Destination for \"Move to library\" mode (relative to local folder above, optional)"
                    )
                    : l10n.tr(
                        "「移动到媒体库」模式下，整理好的文件放到这里（可选）",
                        "Destination for \"Move to library\" mode (optional)"
                    )
            ) {
                HStack(spacing: 6) {
                    TextField(l10n.tr("/影视库", "/Media"), text: $libraryRoot)
                        .textFieldStyle(.roundedBorder)

                    SecondaryActionButton(l10n.tr("浏览…", "Browse…")) {
                        openRemotePicker(.libraryRoot)
                    }
                }
            }
        }
    }

    private func testOutcomeBanner(_ outcome: TestOutcome) -> some View {
        let color: Color = outcome.isSuccess
            ? palette.success
            : (outcome.isAuthFailure ? palette.danger : palette.warning)

        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: outcome.isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(color)

            Text(outcome.message)
                .font(.system(size: TidyreelTypeScale.small))
                .foregroundStyle(palette.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .fill(color.opacity(palette.isDark ? 0.14 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: TidyreelRadii.sm, style: .continuous)
                .strokeBorder(color.opacity(0.32), lineWidth: hairlineWidth)
        )
    }

    private func formRow<Field: View>(
        label: String,
        help: String? = nil,
        error: String? = nil,
        @ViewBuilder field: () -> Field
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: TidyreelTypeScale.body, weight: .medium))
                .foregroundStyle(palette.textMuted)
                .frame(width: 84, alignment: .trailing)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 4) {
                field()
                if let error, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.danger)
                } else if let help, !help.isEmpty {
                    Text(help)
                        .font(.system(size: 11.5))
                        .foregroundStyle(palette.textFaint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var serverHelpText: String? {
        if type == .smb {
            return l10n.tr("SMB 默认端口 445，可以留空", "Default SMB port is 445 (optional)")
        }
        switch currentPreset {
        case .alistApi, .alistDav:
            return l10n.tr("Alist / OpenList 默认端口 5244", "Default Alist / OpenList port is 5244")
        case .synology:
            return l10n.tr("群晖 WebDAV 默认 http 5005、https 5006", "Default Synology WebDAV ports: HTTP 5005, HTTPS 5006")
        case .generic:
            return nil
        }
    }

    private var serverValidationError: String? {
        if let portErr = portErrorMessage, showValidationErrors {
            return portErr
        }
        guard showValidationErrors else { return nil }
        if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return l10n.tr("请填写主机地址", "Host is required")
        }
        return nil
    }

    // MARK: - Actions & Logic

    private func switchConnectionType(to next: ConnectionType) {
        guard next != type else { return }
        type = next
        if next == .smb {
            port = ""
        } else if (next == .alist || next == .webdav) && port.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            port = "5244"
        }
        if next == .webdav && davPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && existing == nil {
            davPath = "/dav"
        }
        invalidateTest()
    }

    private func applyPreset(_ preset: DavPreset) {
        type = preset.connectionType
        port = preset.defaultPort
        davPath = preset.defaultPath
        if preset == .synology { scheme = "http" }
        invalidateTest()
    }

    private func handlePastedHostIfNeeded(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if type == .smb || trimmed.hasPrefix("\\\\") || trimmed.lowercased().hasPrefix("smb://") {
            if let smb = parseSmbEndpoint(trimmed) {
                type = .smb
                let hp = EndpointParts.parse(smb.host)
                if host != hp.host { host = hp.host }
                port = hp.port
                smbShare = smb.base.isEmpty ? smb.share : "\(smb.share)/\(smb.base)"
            }
            return
        }
        guard trimmed.contains("://") else { return }
        let parts = EndpointParts.parse(trimmed)
        guard !parts.host.isEmpty else { return }
        scheme = parts.scheme
        if host != parts.host { host = parts.host }
        if !parts.port.isEmpty { port = parts.port }
        let segs = parts.path.split(separator: "/").map(String.init).filter { !$0.isEmpty }
        if let davIdx = segs.firstIndex(of: "dav") {
            type = .webdav
            davPath = "/" + segs.prefix(davIdx + 1).joined(separator: "/")
            let rest = segs.dropFirst(davIdx + 1).joined(separator: "/")
            if !rest.isEmpty { startDir = "/\(rest)" }
        } else if !segs.isEmpty {
            if type == .webdav {
                davPath = parts.path
            } else {
                startDir = parts.path
            }
        }
    }

    private func chooseLocalFolderWithOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = l10n.tr("选择", "Choose")
        let current = localFolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        if panel.runModal() == .OK, let url = panel.url {
            localFolder = url.path
        }
    }

    private func normalizeApiPath(_ raw: String) -> String {
        let norm = normalizeDir(raw)
        guard type == .alist else { return norm }
        if norm == "/dav" { return "/" }
        if norm.hasPrefix("/dav/") {
            return String(norm.dropFirst(4))
        }
        return norm
    }

    private var autoGeneratedName: String {
        func lastSeg(_ p: String) -> String {
            p.components(separatedBy: CharacterSet(charactersIn: "/\\"))
                .filter { !$0.isEmpty }
                .last ?? ""
        }
        if type != .local {
            let startLeaf = lastSeg(normalizeApiPath(startDir))
            if !startLeaf.isEmpty { return startLeaf }
        }
        if type == .local {
            let folderLeaf = lastSeg(localFolder)
            return folderLeaf.isEmpty ? l10n.tr("本地文件夹", "Local Folder") : folderLeaf
        }
        return host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildDraftConfig() -> ConnectionConfig {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = libraryRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let connId: ConnectionId
        if !isCopy, let existing {
            connId = existing.id
        } else {
            connId = ConnectionId("c\(Int64(Date().timeIntervalSince1970 * 1_000_000))")
        }
        return ConnectionConfig(
            id: connId,
            name: trimmedName.isEmpty ? autoGeneratedName : trimmedName,
            type: type,
            endpoint: composedEndpoint,
            username: (type == .local || trimmedUser.isEmpty) ? nil : trimmedUser,
            libraryRoot: trimmedRoot.isEmpty ? nil : normalizeApiPath(trimmedRoot),
            favorites: isCopy ? [] : (existing?.favorites ?? []),
            startDir: type == .local ? "/" : normalizeApiPath(startDir)
        )
    }

    private func buildDirPasswordsMap() -> [String: String] {
        guard type == .alist else { return [:] }
        var map: [String: String] = [:]
        for item in dirPasswords {
            let p = item.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty && !item.password.isEmpty {
                map[normalizeApiPath(p)] = item.password
            }
        }
        return map
    }

    private func invalidateTest() {
        testTask?.cancel()
        isTesting = false
        testOutcome = nil
        browseValidationHint = nil
    }

    private func openRemotePicker(_ target: PickerTarget) {
        guard isFormValid else {
            showValidationErrors = true
            browseValidationHint = type == .local
                ? l10n.tr("请先选择本地文件夹", "Please choose a local folder first")
                : l10n.tr("请先填写服务器信息，再浏览远程文件夹", "Enter server details before browsing remote folders")
            return
        }
        browseValidationHint = nil
        closePickerBackendIfNeeded()

        let draft = buildDraftConfig()
        let (be, shouldClose) = ConnectionDiagnostics.openTemporaryBackend(
            config: draft,
            password: type == .local ? "" : password,
            dirPasswords: buildDirPasswordsMap(),
            store: store
        )
        if shouldClose {
            pickerBackendToClose = be
        }
        activeFolderPicker = FolderPickerSession(
            target: target,
            title: pickerTitle(for: target),
            initialPath: pickerInitialPath(for: target),
            backend: be
        )
    }

    private func closePickerBackendIfNeeded() {
        guard let backend = pickerBackendToClose else { return }
        pickerBackendToClose = nil
        Task { await backend.close() }
    }

    private func pickerTitle(for target: PickerTarget) -> String {
        switch target {
        case .startDir:
            return l10n.tr("选择连接路径", "Choose Start Path")
        case .libraryRoot:
            return l10n.tr("选择媒体库文件夹", "Choose Media Library Folder")
        case .dirPassword:
            return l10n.tr("选择加密目录", "Choose Protected Folder")
        }
    }

    private func pickerInitialPath(for target: PickerTarget) -> String {
        switch target {
        case .startDir:
            return startDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : normalizeApiPath(startDir)
        case .libraryRoot:
            return libraryRoot.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : normalizeApiPath(libraryRoot)
        case .dirPassword(let id):
            let raw = dirPasswords.first(where: { $0.id == id })?.path ?? ""
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : normalizeApiPath(raw)
        }
    }

    private func applyPickedFolder(_ chosen: String, to target: PickerTarget) {
        switch target {
        case .startDir:
            startDir = chosen == "/" ? "" : chosen
        case .libraryRoot:
            libraryRoot = chosen == "/" ? "" : chosen
        case .dirPassword(let id):
            if let idx = dirPasswords.firstIndex(where: { $0.id == id }) {
                dirPasswords[idx].path = chosen
            }
        }
    }

    private func runConnectionTest() {
        guard isFormValid else {
            showValidationErrors = true
            return
        }
        testTask?.cancel()
        isTesting = true
        testOutcome = nil

        let draft = buildDraftConfig()
        let pw = type == .local ? "" : password
        let dirPws = buildDirPasswordsMap()
        let (be, shouldClose) = ConnectionDiagnostics.openTemporaryBackend(
            config: draft,
            password: pw,
            dirPasswords: dirPws,
            store: store
        )

        testTask = Task {
            defer {
                if shouldClose {
                    Task { await be.close() }
                }
            }
            do {
                try await be.ping()
                let normStart = normalizeDir(draft.startDir)
                if normStart != "/" {
                    let exists = try await be.exists(normStart)
                    if !exists {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isTesting = false
                            testOutcome = TestOutcome(
                                isSuccess: false,
                                isAuthFailure: false,
                                message: l10n.tr(
                                    "服务器连接正常，但连接路径「\(normStart)」不存在",
                                    "Connected to server, but start path \"\(normStart)\" does not exist"
                                )
                            )
                        }
                        return
                    }
                }
                if let lib = draft.libraryRoot, !lib.isEmpty {
                    let normLib = normalizeDir(lib)
                    let exists = try await be.exists(normLib)
                    if !exists {
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            isTesting = false
                            testOutcome = TestOutcome(
                                isSuccess: false,
                                isAuthFailure: false,
                                message: l10n.tr(
                                    "服务器连接正常，但媒体库路径「\(normLib)」不存在",
                                    "Connected to server, but media library \"\(normLib)\" does not exist"
                                )
                            )
                        }
                        return
                    }
                }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    testOutcome = TestOutcome(
                        isSuccess: true,
                        isAuthFailure: false,
                        message: l10n.tr("连接成功", "Connected successfully")
                    )
                }
            } catch let storageErr as StorageError {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    if storageErr.code == .unauthorized {
                        let msg = localizeCoreMessage(l10n, storageErr.message)
                        testOutcome = TestOutcome(
                            isSuccess: false,
                            isAuthFailure: true,
                            message: l10n.tr(
                                "用户名或密码错误（区分大小写）：\(msg)",
                                "Incorrect username or password (case-sensitive): \(msg)"
                            )
                        )
                    } else {
                        testOutcome = TestOutcome(
                            isSuccess: false,
                            isAuthFailure: false,
                            message: ConnectionDiagnostics.enrichOfflineMessage(
                                storageErr.message,
                                config: draft,
                                l10n: l10n
                            )
                        )
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    isTesting = false
                    testOutcome = TestOutcome(
                        isSuccess: false,
                        isAuthFailure: false,
                        message: localizeCoreMessage(l10n, error.localizedDescription)
                    )
                }
            }
        }
    }

    private func saveConnection() {
        guard isFormValid else {
            showValidationErrors = true
            return
        }
        testTask?.cancel()
        let isNew = existing == nil || isCopy
        let draft = buildDraftConfig()
        let pw = type == .local ? "" : password
        let dirPws = buildDirPasswordsMap()
        store.upsertConnection(draft, password: pw, dirPasswords: dirPws)
        if isNew {
            onSavedNewConnection?(draft)
        }
        dismiss()
    }
}
