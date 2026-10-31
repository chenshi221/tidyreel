import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

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

/// Add (when [existing] is null) or edit a connection.
Future<ConnectionDraft?> showConnectionDialog(
  BuildContext context, {
  ConnectionConfig? existing,
}) => showDialog<ConnectionDraft>(
  context: context,
  builder: (_) => _ConnectionDialog(existing: existing),
);

class _ConnectionDialog extends StatefulWidget {
  final ConnectionConfig? existing;

  const _ConnectionDialog({this.existing});

  @override
  State<_ConnectionDialog> createState() => _ConnectionDialogState();
}

class _ConnectionDialogState extends State<_ConnectionDialog> {
  late var _type = widget.existing?.type ?? ConnectionType.alist;
  late final _name = TextEditingController(text: widget.existing?.name);
  late final _endpoint = TextEditingController(text: widget.existing?.endpoint);
  late final _user = TextEditingController(text: widget.existing?.username);
  final _password = TextEditingController();
  late final _root = TextEditingController(text: widget.existing?.libraryRoot);
  var _showErrors = false;

  @override
  void dispose() {
    for (final c in [_name, _endpoint, _user, _password, _root]) {
      c.dispose();
    }
    super.dispose();
  }

  void _save() {
    if (_name.text.trim().isEmpty || _endpoint.text.trim().isEmpty) {
      setState(() => _showErrors = true);
      return;
    }
    String? opt(TextEditingController c) =>
        c.text.trim().isEmpty ? null : c.text.trim();
    Navigator.pop(
      context,
      ConnectionDraft(
        ConnectionConfig(
          id:
              widget.existing?.id ??
              ConnectionId('c${DateTime.now().microsecondsSinceEpoch}'),
          name: _name.text.trim(),
          type: _type,
          endpoint: _endpoint.text.trim(),
          username: _type == ConnectionType.local ? null : opt(_user),
          libraryRoot: opt(_root),
          favorites: widget.existing?.favorites ?? const [],
        ),
        _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final local = _type == ConnectionType.local;
    String? required(TextEditingController c) =>
        _showErrors && c.text.trim().isEmpty ? '必填' : null;
    return AlertDialog(
      title: Text(widget.existing == null ? '添加连接' : '编辑连接'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<ConnectionType>(
                segments: [
                  for (final t in ConnectionType.values)
                    ButtonSegment(
                      value: t,
                      icon: Icon(connectionTypeIcon(t)),
                      label: Text(connectionTypeLabel(t)),
                    ),
                ],
                selected: {_type},
                onSelectionChanged: (v) => setState(() => _type = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: InputDecoration(
                  labelText: '名称',
                  errorText: required(_name),
                ),
              ),
              TextField(
                controller: _endpoint,
                decoration: InputDecoration(
                  labelText: local ? '文件夹路径' : '服务器地址',
                  hintText: local
                      ? '/Users/me/Downloads'
                      : 'http://nas.local:5244',
                  errorText: required(_endpoint),
                ),
              ),
              if (!local) ...[
                TextField(
                  controller: _user,
                  decoration: const InputDecoration(labelText: '用户名'),
                ),
                // Saved to the keychain via connectionPasswordsProvider.
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: '密码'),
                ),
              ],
              TextField(
                controller: _root,
                decoration: const InputDecoration(
                  labelText: '媒体库根目录',
                  hintText: '/影视库（移动模式下的目标）',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }
}
