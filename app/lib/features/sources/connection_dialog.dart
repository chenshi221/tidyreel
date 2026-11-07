import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../../data/smb_backend.dart' show SmbTarget, parseSmbEndpoint;
import 'folder_picker.dart';
import 'sources_providers.dart' show ConnCheck, ConnStatus, FolderLister;

String connectionTypeLabel(ConnectionType t) => switch (t) {
  ConnectionType.alist => 'Alist',
  ConnectionType.webdav => 'WebDAV',
  ConnectionType.smb => 'SMB',
  ConnectionType.local => '本地',
};

IconData connectionTypeIcon(ConnectionType t) => switch (t) {
  ConnectionType.alist => CupertinoIcons.cloud,
  ConnectionType.webdav => CupertinoIcons.globe,
  ConnectionType.smb => CupertinoIcons.square_stack_3d_up,
  ConnectionType.local => CupertinoIcons.desktopcomputer,
};

/// The three choices at the top of the dialog; Alist and WebDAV share one.
enum _Kind { dav, smb, local }

/// 模板 under WebDAV / Alist: fills type, port and path for common servers.
enum DavTemplate {
  alistApi('Alist / OpenList（API，推荐）', ConnectionType.alist, '5244', ''),
  alistDav('Alist / OpenList（WebDAV）', ConnectionType.webdav, '5244', '/dav'),
  synology('群晖 WebDAV', ConnectionType.webdav, '5005', ''),
  generic('通用 WebDAV', ConnectionType.webdav, '', '');

  final String label;
  final ConnectionType type;
  final String port;
  final String path;

  const DavTemplate(this.label, this.type, this.port, this.path);
}

class ConnectionDraft {
  final ConnectionConfig config;
  final String password;

  const ConnectionDraft(this.config, this.password);
}

/// Server address split into the parts users actually know.
class EndpointParts {
  final String scheme;
  final String host;
  final String port;
  final String path;

  const EndpointParts({
    this.scheme = 'http',
    this.host = '',
    this.port = '',
    this.path = '',
  });

  /// Accepts full URLs ("https://nas:5244/dav/"), bare hosts ("192.168.1.2")
  /// and host:port ("nas.local:5244").
  static EndpointParts parse(String endpoint) {
    var s = endpoint.trim();
    if (s.isEmpty) return const EndpointParts();
    if (!s.contains('://')) s = 'http://$s';
    final u = Uri.tryParse(s);
    if (u == null || u.host.isEmpty) {
      return EndpointParts(host: endpoint.trim());
    }
    final path = Uri.decodeComponent(u.path).replaceFirst(RegExp(r'/+$'), '');
    return EndpointParts(
      scheme: u.scheme == 'https' ? 'https' : 'http',
      host: u.host,
      port: u.hasPort ? '${u.port}' : '',
      path: path,
    );
  }

  /// "http://host[:port][/path]"; path is normalized to one leading slash.
  String compose() {
    final segs = path.split('/').where((s) => s.trim().isNotEmpty).toList();
    final h = host.trim();
    final hostPart = h.contains(':') && !h.startsWith('[') ? '[$h]' : h;
    final portPart = port.trim().isEmpty ? '' : ':${port.trim()}';
    final pathPart = segs.isEmpty ? '' : '/${segs.join('/')}';
    return '$scheme://$hostPart$portPart$pathPart';
  }
}

/// Add (when [existing] is null) or edit a connection. [initialPassword] is the
/// saved one (from secrets.json) so editing never silently clears it.
/// [tester] backs the 测试连接 button, [lister] the 浏览… folder pickers.
/// [copy]: [existing] is a template for a new connection (复制).
Future<ConnectionDraft?> showConnectionDialog(
  BuildContext context, {
  ConnectionConfig? existing,
  String? initialPassword,
  bool copy = false,
  Future<ConnCheck> Function(ConnectionConfig, String password)? tester,
  FolderLister? lister,
}) => showDialog<ConnectionDraft>(
  context: context,
  builder: (_) => _ConnectionDialog(
    existing: existing,
    initialPassword: initialPassword,
    copy: copy,
    tester: tester,
    lister: lister,
  ),
);

class _ConnectionDialog extends StatefulWidget {
  final ConnectionConfig? existing;
  final String? initialPassword;
  final bool copy;
  final Future<ConnCheck> Function(ConnectionConfig, String)? tester;
  final FolderLister? lister;

  const _ConnectionDialog({
    this.existing,
    this.initialPassword,
    this.copy = false,
    this.tester,
    this.lister,
  });

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

const _defaultPort = '5244';
const _davPath = '/dav';
const _smbPort = '445';

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late var _type = widget.existing?.type ?? ConnectionType.alist;
  late final SmbTarget? _smb = widget.existing?.type == ConnectionType.smb
      ? parseSmbEndpoint(widget.existing!.endpoint)
      : null;
  late final EndpointParts _initial = switch (widget.existing?.type) {
    null || ConnectionType.local => const EndpointParts(port: _defaultPort),
    ConnectionType.smb => EndpointParts.parse(_smb?.host ?? ''),
    _ => EndpointParts.parse(widget.existing!.endpoint),
  };
  late final _share = TextEditingController(
    text: [
      ?_smb?.share,
      if (_smb?.base.isNotEmpty ?? false) _smb!.base,
    ].join('/'),
  );

  late var _scheme = _initial.scheme;
  late final _name = TextEditingController(
    text: widget.copy ? null : widget.existing?.name,
  );
  late final _host = TextEditingController(text: _initial.host);
  late final _port = TextEditingController(text: _initial.port);
  late final _path = TextEditingController(
    text: widget.existing == null && _type == ConnectionType.webdav
        ? _davPath
        : _initial.path,
  );
  late final _folder = TextEditingController(
    text: widget.existing?.type == ConnectionType.local
        ? widget.existing!.endpoint
        : '',
  );
  late final _user = TextEditingController(
    text: widget.existing?.username ?? (widget.existing == null ? 'admin' : ''),
  );
  late final _password = TextEditingController(text: widget.initialPassword);
  late final _root = TextEditingController(text: widget.existing?.libraryRoot);
  late final _start = TextEditingController(
    text: widget.existing?.startDir == '/' ? '' : widget.existing?.startDir,
  );
  var _showErrors = false;
  var _showPassword = false;
  var _testing = false;
  ConnCheck? _testResult;

  bool get _local => _type == ConnectionType.local;
  bool get _isSmb => _type == ConnectionType.smb;
  _Kind get _kind => switch (_type) {
    ConnectionType.smb => _Kind.smb,
    ConnectionType.local => _Kind.local,
    _ => _Kind.dav,
  };

  /// The template the current fields look like (for the 模板 menu label).
  DavTemplate get _template => _type == ConnectionType.alist
      ? DavTemplate.alistApi
      : _path.text.trim() == _davPath
      ? DavTemplate.alistDav
      : _port.text.trim() == '5005' || _port.text.trim() == '5006'
      ? DavTemplate.synology
      : DavTemplate.generic;

  @override
  void initState() {
    super.initState();
    for (final c in [_host, _port, _path, _folder, _user, _password, _share]) {
      c.addListener(_onEdit);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _host,
      _port,
      _path,
      _folder,
      _user,
      _password,
      _root,
      _start,
      _share,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Any edit invalidates a previous test result and refreshes the preview.
  void _onEdit() => setState(() => _testResult = null);

  EndpointParts get _parts => EndpointParts(
    scheme: _scheme,
    host: _host.text,
    port: _port.text,
    path: _type == ConnectionType.webdav ? _path.text : '',
  );

  String get _endpoint {
    if (_local) return _folder.text.trim();
    if (_isSmb) {
      final port = _port.text.trim();
      final host = _host.text.trim();
      final share = _share.text
          .split(RegExp(r'[/\\]'))
          .where((s) => s.trim().isNotEmpty)
          .join('/');
      return 'smb://$host${port.isEmpty || port == _smbPort ? '' : ':$port'}/$share';
    }
    return _parts.compose();
  }

  /// A full URL pasted into 主机 is split across the fields.
  void _onHostChanged(String v) {
    // \\nas\影视 or smb://nas/影视 pasted into 主机.
    if (_isSmb || v.startsWith(r'\\') || v.toLowerCase().startsWith('smb://')) {
      final t = parseSmbEndpoint(v);
      if (t == null) return;
      setState(() {
        _type = ConnectionType.smb;
        final hp = EndpointParts.parse(t.host);
        _host.text = hp.host;
        _port.text = hp.port;
        _share.text = [t.share, if (t.base.isNotEmpty) t.base].join('/');
      });
      return;
    }
    if (!v.contains('://')) return;
    final p = EndpointParts.parse(v);
    if (p.host.isEmpty) return;
    setState(() {
      _scheme = p.scheme;
      _host.text = p.host;
      if (p.port.isNotEmpty) _port.text = p.port;
      final segs = p.path.split('/').where((s) => s.isNotEmpty).toList();
      final dav = segs.indexOf('dav');
      if (dav >= 0) {
        // Alist / OpenList WebDAV: mount up to /dav, the rest is where to open.
        _type = ConnectionType.webdav;
        _path.text = '/${segs.take(dav + 1).join('/')}';
        final rest = segs.skip(dav + 1).join('/');
        if (rest.isNotEmpty) _start.text = '/$rest';
      } else if (segs.isNotEmpty) {
        // Alist's API has no URL path: treat it as the folder to open.
        if (_type == ConnectionType.webdav) {
          _path.text = p.path;
        } else {
          _start.text = p.path;
        }
      }
    });
  }

  void _setKind(_Kind k) => setState(() {
    if (k == _kind) return;
    _type = switch (k) {
      _Kind.dav => ConnectionType.alist,
      _Kind.smb => ConnectionType.smb,
      _Kind.local => ConnectionType.local,
    };
    if (k == _Kind.smb) _port.text = '';
    if (k == _Kind.dav && _port.text.trim().isEmpty) _port.text = _defaultPort;
    _testResult = null;
  });

  void _setTemplate(DavTemplate t) => setState(() {
    _type = t.type;
    _port.text = t.port;
    _path.text = t.path;
    if (t == DavTemplate.synology) _scheme = 'http';
    _testResult = null;
  });

  String? _portError() {
    final s = _port.text.trim();
    if (s.isEmpty) return null;
    final n = int.tryParse(s);
    return n == null || n < 1 || n > 65535 ? '端口应为 1–65535' : null;
  }

  bool _valid() => _local
      ? _folder.text.trim().isNotEmpty
      : _host.text.trim().isNotEmpty &&
            _portError() == null &&
            (!_isSmb || _share.text.trim().isNotEmpty);

  /// Alist's API paths never start with the WebDAV mount: "/dav/外接硬盘"
  /// typed into an Alist connection means "/外接硬盘".
  String _apiPath(String text) {
    final d = normalizeDir(text);
    if (_type != ConnectionType.alist) return d;
    return d == _davPath ? '/' : d.replaceFirst(RegExp('^$_davPath/'), '/');
  }

  /// Empty 名称: last folder of 连接路径, else the host / local folder name.
  String get _autoName {
    String last(String path) =>
        path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).lastOrNull ??
        '';
    final start = last(_apiPath(_start.text));
    if (start.isNotEmpty) return start;
    return _local ? last(_folder.text) : _host.text.trim();
  }

  ConnectionConfig _config() {
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    final root = opt(_root);
    return ConnectionConfig(
      id: !widget.copy && widget.existing != null
          ? widget.existing!.id
          : ConnectionId('c${DateTime.now().microsecondsSinceEpoch}'),
      name: _name.text.trim().isEmpty ? _autoName : _name.text.trim(),
      type: _type,
      endpoint: _endpoint,
      username: _local ? null : opt(_user),
      libraryRoot: root == null ? null : _apiPath(root),
      favorites: widget.copy
          ? const []
          : widget.existing?.favorites ?? const [],
      startDir: _apiPath(_start.text),
    );
  }

  void _save() {
    if (!_valid()) {
      setState(() => _showErrors = true);
      return;
    }
    Navigator.pop(
      context,
      ConnectionDraft(_config(), _local ? '' : _password.text),
    );
  }

  Future<void> _test() async {
    if (!_valid()) {
      setState(() => _showErrors = true);
      return;
    }
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final r = await widget.tester!(_config(), _password.text);
    if (!mounted) return;
    setState(() {
      _testing = false;
      _testResult = r;
    });
  }

  /// 浏览…: pick [c]'s folder on the server with the unsaved settings.
  Future<void> _browse(TextEditingController c, String title) async {
    if (!_valid()) {
      setState(() => _showErrors = true);
      return;
    }
    final config = _config();
    final password = _local ? '' : _password.text;
    final dir = await showRemoteFolderPicker(
      context,
      title: title,
      initial: c.text.trim().isEmpty ? '/' : _apiPath(c.text),
      list: (dir) => widget.lister!(config, password, dir),
    );
    if (!mounted) return;
    if (dir != null) c.text = dir == '/' ? '' : dir;
  }

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(
      initialDirectory: _folder.text.trim().isEmpty ? null : _folder.text,
    );
    if (!mounted) return;
    if (dir != null) _folder.text = dir;
  }

  Widget _withBrowse(Widget field, VoidCallback onBrowse) =>
      widget.lister == null
      ? field
      : Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: field),
            const SizedBox(width: 6),
            OutlinedButton(onPressed: onBrowse, child: const Text('浏览…')),
          ],
        );

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    String? required(TextEditingController c) =>
        _showErrors && c.text.trim().isEmpty ? '必填' : null;

    TextField field(
      String key,
      TextEditingController c, {
      String? hint,
      String? error,
      bool obscure = false,
      Widget? suffix,
      ValueChanged<String>? onChanged,
      TextInputType? keyboard,
    }) => TextField(
      key: ValueKey('field-$key'),
      controller: c,
      obscureText: obscure,
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: keyboard,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        hintText: hint,
        errorText: error,
        suffixIcon: suffix,
      ),
      onChanged: onChanged,
    );

    final server = <Widget>[
      if (_kind == _Kind.dav)
        FormRow(
          label: '模板',
          child: Align(
            alignment: Alignment.centerLeft,
            child: _TemplateMenu(value: _template, onChanged: _setTemplate),
          ),
        ),
      FormRow(
        label: '服务器',
        help: switch (_template) {
          _ when _isSmb => 'SMB 默认端口 445，可以留空',
          DavTemplate.alistApi ||
          DavTemplate.alistDav => 'Alist / OpenList 默认端口 5244',
          DavTemplate.synology => '群晖 WebDAV 默认 http 5005、https 5006',
          DavTemplate.generic => null,
        },
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!_isSmb) ...[
              _SchemeMenu(
                value: _scheme,
                onChanged: (v) => setState(() {
                  _scheme = v;
                  _testResult = null;
                }),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: field(
                '主机',
                _host,
                hint: '主机名或 IP，如 192.168.1.10',
                error: required(_host),
                onChanged: _onHostChanged,
              ),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Text(':', style: TextStyle(color: p.textFaint)),
            ),
            const SizedBox(width: 6),
            SizedBox(
              width: 76,
              child: field(
                '端口',
                _port,
                hint: _isSmb ? _smbPort : _defaultPort,
                keyboard: TextInputType.number,
                error: _showErrors ? _portError() : null,
              ),
            ),
          ],
        ),
      ),
      if (_isSmb)
        FormRow(
          label: '共享名',
          help: '比如 影视、video；也可以写到子文件夹，如 影视/下载',
          child: field('共享名', _share, hint: '影视', error: required(_share)),
        ),
      if (_type == ConnectionType.webdav)
        FormRow(
          label: '路径',
          help: 'Alist / OpenList 填 /dav；其他 WebDAV 服务按实际路径填写，可以留空',
          child: field('路径', _path, hint: _davPath),
        ),
      FormRow(
        label: '',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: p.hover,
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Row(
            children: [
              Icon(CupertinoIcons.link, size: 13, color: p.textFaint),
              const SizedBox(width: 6),
              Expanded(
                child: SelectableText(
                  _host.text.trim().isEmpty ? '填写主机后显示完整地址' : _endpoint,
                  key: const ValueKey('endpoint-preview'),
                  style: TextStyle(
                    fontFamily: monoFamily,
                    fontFamilyFallback: monoFallback,
                    fontSize: 12,
                    color: p.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      const SizedBox(height: 6),
      FormRow(
        label: '用户名',
        help: '区分大小写',
        child: field('用户名', _user, hint: 'admin'),
      ),
      FormRow(
        label: '密码',
        help: '只保存在这台电脑上',
        child: field(
          '密码',
          _password,
          obscure: !_showPassword,
          suffix: IconButton(
            tooltip: _showPassword ? '隐藏密码' : '显示密码',
            iconSize: 15,
            icon: Icon(
              _showPassword ? CupertinoIcons.eye_slash : CupertinoIcons.eye,
            ),
            onPressed: () => setState(() => _showPassword = !_showPassword),
          ),
        ),
      ),
    ];

    final local = <Widget>[
      FormRow(
        label: '文件夹',
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: field(
                '文件夹',
                _folder,
                hint: '/Users/me/Downloads',
                error: required(_folder),
              ),
            ),
            const SizedBox(width: 6),
            OutlinedButton(onPressed: _pickFolder, child: const Text('选择…')),
          ],
        ),
      ),
    ];

    final result = _testResult;
    final resultColor = switch (result?.status) {
      ConnStatus.connected => p.success,
      ConnStatus.authFailed => p.danger,
      _ => p.warning,
    };

    return MacSheet(
      child: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.existing == null || widget.copy ? '添加连接' : '编辑连接',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: 14),
                  Center(
                    child: Segmented<_Kind>(
                      key: const ValueKey('conn-kind'),
                      options: const {
                        _Kind.dav: 'WebDAV / Alist',
                        _Kind.smb: 'SMB',
                        _Kind.local: '本地',
                      },
                      value: _kind,
                      onChanged: _setKind,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(switch (_type) {
                      ConnectionType.alist =>
                        '通过 Alist / OpenList 的 API 连接，批量改名更快',
                      ConnectionType.webdav =>
                        '通用 WebDAV：Alist、OpenList、群晖、Nextcloud 等',
                      ConnectionType.smb => '局域网共享文件夹：NAS、路由器、Windows 共享',
                      ConnectionType.local => '直接整理这台电脑上的文件夹',
                    }, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 14, 26, 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FormRow(
                      label: '名称',
                      child: field('名称', _name, hint: '留空时自动用文件夹名'),
                    ),
                    ...(_local ? local : server),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Divider(),
                    ),
                    FormRow(
                      label: '连接路径',
                      help: '只能访问这个路径及以下，比如 /PC；留空可访问全部',
                      child: _withBrowse(
                        field('连接路径', _start, hint: '/'),
                        () => _browse(_start, '选择连接路径'),
                      ),
                    ),
                    FormRow(
                      label: '媒体库',
                      help: '「移动到媒体库」模式下，整理好的文件放到这里（可选）',
                      child: _withBrowse(
                        field('媒体库', _root, hint: '/影视库'),
                        () => _browse(_root, '选择媒体库文件夹'),
                      ),
                    ),
                    if (result != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        key: const ValueKey('test-result'),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: resultColor.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(Radii.sm),
                          border: Border.all(
                            color: resultColor.withValues(alpha: 0.3),
                            width: hairline,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              result.status == ConnStatus.connected
                                  ? CupertinoIcons.checkmark_circle_fill
                                  : CupertinoIcons.exclamationmark_circle_fill,
                              size: 16,
                              color: resultColor,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: SelectableText(
                                result.status == ConnStatus.connected
                                    ? '连接成功'
                                    : (result.detail ?? '连接失败'),
                                style: TextStyle(
                                  fontSize: TypeScale.small,
                                  color: p.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 22, 18),
              child: Row(
                children: [
                  if (widget.tester != null)
                    TextButton.icon(
                      onPressed: _testing ? null : _test,
                      icon: _testing
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(
                              CupertinoIcons.bolt_horizontal,
                              size: 15,
                            ),
                      label: const Text('测试连接'),
                    ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: const Text('保存')),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 模板 popup: Alist API / Alist WebDAV / 群晖 / 通用.
class _TemplateMenu extends StatelessWidget {
  final DavTemplate value;
  final ValueChanged<DavTemplate> onChanged;

  const _TemplateMenu({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopupMenuButton<DavTemplate>(
      key: const ValueKey('dav-template'),
      tooltip: '选择服务器类型，自动填好端口和路径',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final t in DavTemplate.values)
          PopupMenuItem(
            key: ValueKey('template-${t.name}'),
            value: t,
            height: 32,
            child: Text(t.label),
          ),
      ],
      child: Container(
        height: 31,
        padding: const EdgeInsets.only(left: 10, right: 6),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: p.lineStrong, width: hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value.label, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: 11,
              color: p.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

/// http / https popup button.
class _SchemeMenu extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;

  const _SchemeMenu({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return PopupMenuButton<String>(
      key: const ValueKey('scheme'),
      tooltip: '协议',
      initialValue: value,
      onSelected: onChanged,
      position: PopupMenuPosition.under,
      itemBuilder: (_) => [
        for (final s in ['http', 'https'])
          PopupMenuItem(value: s, height: 30, child: Text(s)),
      ],
      child: Container(
        height: 31,
        padding: const EdgeInsets.only(left: 9, right: 5),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: p.lineStrong, width: hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('$value://', style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 2),
            Icon(
              CupertinoIcons.chevron_up_chevron_down,
              size: 11,
              color: p.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}
