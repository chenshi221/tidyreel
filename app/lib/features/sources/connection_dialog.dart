import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../ui/tokens.dart';
import 'sources_providers.dart' show ConnCheck, ConnStatus;

String connectionTypeLabel(ConnectionType t) => switch (t) {
  ConnectionType.alist => 'Alist',
  ConnectionType.webdav => 'WebDAV',
  ConnectionType.local => '本地',
};

IconData connectionTypeIcon(ConnectionType t) => switch (t) {
  ConnectionType.alist => Icons.cloud_outlined,
  ConnectionType.webdav => Icons.dns_outlined,
  ConnectionType.local => Icons.computer_outlined,
};

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
/// saved one (read from the keychain) so editing never silently clears it.
/// [tester] backs the 测试连接 button.
Future<ConnectionDraft?> showConnectionDialog(
  BuildContext context, {
  ConnectionConfig? existing,
  String? initialPassword,
  Future<ConnCheck> Function(ConnectionConfig, String password)? tester,
}) => showDialog<ConnectionDraft>(
  context: context,
  builder: (_) => _ConnectionDialog(
    existing: existing,
    initialPassword: initialPassword,
    tester: tester,
  ),
);

class _ConnectionDialog extends StatefulWidget {
  final ConnectionConfig? existing;
  final String? initialPassword;
  final Future<ConnCheck> Function(ConnectionConfig, String)? tester;

  const _ConnectionDialog({this.existing, this.initialPassword, this.tester});

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

const _defaultPort = '5244';
const _davPath = '/dav';

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late var _type = widget.existing?.type ?? ConnectionType.alist;
  late final EndpointParts _initial =
      widget.existing == null || widget.existing!.type == ConnectionType.local
      ? const EndpointParts(port: _defaultPort)
      : EndpointParts.parse(widget.existing!.endpoint);

  late var _scheme = _initial.scheme;
  late final _name = TextEditingController(text: widget.existing?.name);
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
  var _showErrors = false;
  var _showPassword = false;
  var _testing = false;
  ConnCheck? _testResult;

  bool get _local => _type == ConnectionType.local;

  @override
  void initState() {
    super.initState();
    for (final c in [_host, _port, _path, _folder, _user, _password]) {
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

  String get _endpoint => _local ? _folder.text.trim() : _parts.compose();

  /// A full URL pasted into 主机 is split across the fields.
  void _onHostChanged(String v) {
    if (!v.contains('://')) return;
    final p = EndpointParts.parse(v);
    if (p.host.isEmpty) return;
    setState(() {
      _scheme = p.scheme;
      _host.text = p.host;
      if (p.port.isNotEmpty) _port.text = p.port;
      if (p.path.isNotEmpty) _path.text = p.path;
      if (p.path.isNotEmpty && _type == ConnectionType.alist) {
        // An address with a path is a WebDAV mount (e.g. Alist's /dav).
        _type = p.path.endsWith(_davPath) ? ConnectionType.webdav : _type;
      }
    });
  }

  void _setType(ConnectionType t) => setState(() {
    if (t == ConnectionType.webdav && _path.text.trim().isEmpty) {
      _path.text = _davPath;
    }
    _type = t;
    _testResult = null;
  });

  String? _portError() {
    final s = _port.text.trim();
    if (s.isEmpty) return null;
    final n = int.tryParse(s);
    return n == null || n < 1 || n > 65535 ? '端口应为 1–65535' : null;
  }

  bool _valid() =>
      _name.text.trim().isNotEmpty &&
      (_local
          ? _folder.text.trim().isNotEmpty
          : _host.text.trim().isNotEmpty && _portError() == null);

  ConnectionConfig _config() {
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    return ConnectionConfig(
      id:
          widget.existing?.id ??
          ConnectionId('c${DateTime.now().microsecondsSinceEpoch}'),
      name: _name.text.trim(),
      type: _type,
      endpoint: _endpoint,
      username: _local ? null : opt(_user),
      libraryRoot: opt(_root),
      favorites: widget.existing?.favorites ?? const [],
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

  Future<void> _pickFolder() async {
    final dir = await getDirectoryPath(
      initialDirectory: _folder.text.trim().isEmpty ? null : _folder.text,
    );
    if (dir != null) _folder.text = dir;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    String? required(TextEditingController c) =>
        _showErrors && c.text.trim().isEmpty ? '必填' : null;
    const gap = SizedBox(height: 14);

    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: theme.textTheme.titleSmall),
    );

    final server = <Widget>[
      label('服务器'),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 112,
            child: DropdownButtonFormField<String>(
              key: const ValueKey('scheme'),
              initialValue: _scheme,
              decoration: const InputDecoration(labelText: '协议'),
              items: const [
                DropdownMenuItem(value: 'http', child: Text('http')),
                DropdownMenuItem(value: 'https', child: Text('https')),
              ],
              onChanged: (v) => setState(() {
                _scheme = v!;
                _testResult = null;
              }),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _host,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: '主机 / IP',
                hintText: '192.168.1.10 或 nas.local',
                errorText: required(_host),
              ),
              onChanged: _onHostChanged,
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 104,
            child: TextField(
              controller: _port,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: '端口',
                hintText: _defaultPort,
                errorText: _showErrors ? _portError() : null,
              ),
            ),
          ),
        ],
      ),
      if (_type == ConnectionType.webdav) ...[
        gap,
        TextField(
          controller: _path,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: '路径',
            hintText: _davPath,
            helperText: 'Alist / OpenList 的 WebDAV 填 /dav；其他 WebDAV 服务按实际路径填写',
          ),
        ),
      ],
      const SizedBox(height: 8),
      Row(
        children: [
          Icon(Icons.link, size: 14, color: p.textFaint),
          const SizedBox(width: 6),
          Expanded(
            child: SelectableText(
              _host.text.trim().isEmpty ? '填写主机后显示完整地址' : _endpoint,
              key: const ValueKey('endpoint-preview'),
              style: TextStyle(
                fontFamily: monoFamily,
                fontFamilyFallback: monoFallback,
                fontSize: 12.5,
                color: p.textMuted,
              ),
            ),
          ),
        ],
      ),
      gap,
      label('账号'),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _user,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: '用户名',
                helperText: '区分大小写',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _password,
              obscureText: !_showPassword,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: '密码',
                helperText: '保存在系统钥匙串',
                suffixIcon: IconButton(
                  tooltip: _showPassword ? '隐藏密码' : '显示密码',
                  iconSize: 18,
                  icon: Icon(
                    _showPassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                  ),
                  onPressed: () =>
                      setState(() => _showPassword = !_showPassword),
                ),
              ),
            ),
          ),
        ],
      ),
    ];

    final local = <Widget>[
      label('文件夹'),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _folder,
              decoration: InputDecoration(
                labelText: '文件夹路径',
                hintText: '/Users/me/Downloads',
                errorText: required(_folder),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: OutlinedButton(
              onPressed: _pickFolder,
              child: const Text('选择…'),
            ),
          ),
        ],
      ),
    ];

    final result = _testResult;
    final resultColor = switch (result?.status) {
      ConnStatus.connected => p.success,
      ConnStatus.authFailed => p.danger,
      _ => p.warning,
    };

    return AlertDialog(
      title: Text(widget.existing == null ? '添加连接' : '编辑连接'),
      contentPadding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
      content: SizedBox(
        width: 500,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<ConnectionType>(
                showSelectedIcon: false,
                segments: [
                  for (final t in ConnectionType.values)
                    ButtonSegment(
                      value: t,
                      icon: Icon(connectionTypeIcon(t), size: 18),
                      label: Text(connectionTypeLabel(t)),
                    ),
                ],
                selected: {_type},
                onSelectionChanged: (v) => _setType(v.first),
              ),
              const SizedBox(height: 6),
              Text(switch (_type) {
                ConnectionType.alist =>
                  '通过 Alist / OpenList 的 API 连接，批量改名更快。端口默认 5244。',
                ConnectionType.webdav =>
                  '通用 WebDAV。连接 Alist / OpenList 时，路径填 /dav。',
                ConnectionType.local => '直接整理这台电脑上的文件夹。',
              }, style: theme.textTheme.bodySmall),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: '名称',
                  hintText: '比如：家里的 NAS',
                  errorText: required(_name),
                ),
              ),
              gap,
              ...(_local ? local : server),
              gap,
              label('整理'),
              TextField(
                controller: _root,
                decoration: const InputDecoration(
                  labelText: '媒体库根目录（可选）',
                  hintText: '/影视库',
                  helperText: '「移动到媒体库」模式下，整理好的文件放到这里',
                ),
              ),
              if (result != null) ...[
                const SizedBox(height: 14),
                Container(
                  key: const ValueKey('test-result'),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: resultColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(Radii.md),
                    border: Border.all(
                      color: resultColor.withValues(alpha: 0.35),
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        result.status == ConnStatus.connected
                            ? Icons.check_circle_outline
                            : Icons.error_outline,
                        size: 18,
                        color: resultColor,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: SelectableText(
                          result.status == ConnStatus.connected
                              ? '连接成功'
                              : (result.detail ?? '连接失败'),
                          style: TextStyle(fontSize: 13, color: p.text),
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
      actionsPadding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      actions: [
        Row(
          children: [
            if (widget.tester != null)
              TextButton.icon(
                onPressed: _testing ? null : _test,
                icon: _testing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.6),
                      )
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('测试连接'),
              ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            const SizedBox(width: 8),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
      ],
    );
  }
}
