import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../data/watch_rules_store.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';
import '../sources/connection_dialog.dart'
    show connectionTypeIcon, connectionTypeLabel;
import '../sources/folder_picker.dart';

const _intervalOptions = <int, String>{
  5: '5 分钟',
  10: '10 分钟',
  15: '15 分钟',
  30: '30 分钟',
  60: '60 分钟',
};

/// Add or edit one lightweight watch-mode rule. Returns null if cancelled.
Future<WatchRule?> showWatchRuleDialog(
  BuildContext context, {
  required List<ConnectionConfig> connections,
  WatchRule? existing,
  Future<List<RemoteEntry>> Function(ConnectionId connId, String dir)?
  remoteLister,
  bool isDemo = false,
}) => showDialog<WatchRule>(
  context: context,
  builder: (_) => _WatchRuleDialog(
    connections: connections,
    existing: existing,
    remoteLister: remoteLister,
    isDemo: isDemo,
  ),
);

class _WatchRuleDialog extends StatefulWidget {
  final List<ConnectionConfig> connections;
  final WatchRule? existing;
  final Future<List<RemoteEntry>> Function(ConnectionId connId, String dir)?
  remoteLister;
  final bool isDemo;

  const _WatchRuleDialog({
    required this.connections,
    this.existing,
    this.remoteLister,
    required this.isDemo,
  });

  @override
  State<_WatchRuleDialog> createState() => _WatchRuleDialogState();
}

class _WatchRuleDialogState extends State<_WatchRuleDialog> {
  late ConnectionId _connId =
      widget.existing?.connection ?? widget.connections.first.id;
  late final TextEditingController _path = TextEditingController(
    text:
        widget.existing?.path ??
        (_selectedConn.favorites.firstOrNull ?? _selectedConn.startDir),
  );
  late int _interval =
      _intervalOptions.containsKey(widget.existing?.intervalMinutes)
      ? widget.existing!.intervalMinutes
      : 10;
  late OrganizeMode _mode = widget.existing?.mode ?? OrganizeMode.inPlace;
  late bool _scrape = widget.existing?.scrape ?? false;
  late bool _autoRun = widget.existing?.autoRunHighConfidence ?? false;
  var _showErrors = false;
  String? _browseHint;

  ConnectionConfig get _selectedConn => widget.connections.firstWhere(
    (c) => c.id == _connId,
    orElse: () => widget.connections.first,
  );

  bool get _isLocal => _selectedConn.type == ConnectionType.local;

  bool get _hasLibraryRoot {
    final lr = _selectedConn.libraryRoot?.trim();
    return lr != null && lr.isNotEmpty;
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  void _selectConnection(ConnectionId id) {
    if (id == _connId) return;
    setState(() {
      _connId = id;
      _browseHint = null;
      final c = _selectedConn;
      if (widget.existing == null) {
        _path.text = c.favorites.firstOrNull ?? c.startDir;
      }
      if (_mode == OrganizeMode.moveToLibrary && !_hasLibraryRoot) {
        _mode = OrganizeMode.inPlace;
      }
    });
  }

  Future<void> _browse() async {
    setState(() => _browseHint = null);
    final conn = _selectedConn;
    if (_isLocal && !widget.isDemo && Directory(conn.endpoint).existsSync()) {
      final initialReal = _path.text.trim().isEmpty || _path.text.trim() == '/'
          ? conn.endpoint
          : p.joinAll([
              conn.endpoint,
              ...normalizeDir(_path.text).split('/').where((s) => s.isNotEmpty),
            ]);
      final picked = await getDirectoryPath(
        initialDirectory: Directory(initialReal).existsSync()
            ? initialReal
            : conn.endpoint,
      );
      if (!mounted || picked == null) return;
      final rootNorm = p.normalize(conn.endpoint);
      final pickedNorm = p.normalize(picked);
      if (pickedNorm == rootNorm) {
        setState(() => _path.text = '/');
      } else if (p.isWithin(rootNorm, pickedNorm)) {
        final rel = p.relative(pickedNorm, from: rootNorm);
        final posixRel = '/${p.split(rel).join('/')}';
        setState(() => _path.text = normalizeDir(posixRel));
      } else {
        setState(() => _browseHint = '所选文件夹不在连接根目录（$rootNorm）内，请重新选择或直接填写相对路径');
      }
      return;
    }

    final lister = widget.remoteLister;
    if (lister == null) return;
    final dir = await showRemoteFolderPicker(
      context,
      title: '选择监控目录',
      initial: _path.text.trim().isEmpty ? '/' : normalizeDir(_path.text),
      list: (d) => lister(conn.id, d),
    );
    if (!mounted || dir == null) return;
    setState(() => _path.text = dir);
  }

  void _save() {
    final trimmed = _path.text.trim();
    if (trimmed.isEmpty ||
        (_mode == OrganizeMode.moveToLibrary && !_hasLibraryRoot)) {
      setState(() => _showErrors = true);
      return;
    }

    final id =
        widget.existing?.id ?? 'w-${DateTime.now().microsecondsSinceEpoch}';
    final rule = WatchRule(
      id: id,
      connection: _connId,
      path: normalizeDir(trimmed),
      enabled: widget.existing?.enabled ?? true,
      intervalMinutes: _interval,
      mode: _mode,
      scrape: _scrape,
      autoRunHighConfidence: _autoRun,
      lastScanAt: widget.existing?.lastScanAt,
      lastStatus: widget.existing?.lastStatus ?? '',
    );
    Navigator.pop(context, rule);
  }

  @override
  Widget build(BuildContext context) {
    final pColors = Palette.of(context);
    final theme = Theme.of(context);
    final conn = _selectedConn;
    final quickPaths = <String>{
      for (final f in conn.favorites) normalizeDir(f),
      if (normalizeDir(conn.startDir) != '/') normalizeDir(conn.startDir),
    }.toList();
    final modeWarning = _mode == OrganizeMode.moveToLibrary && !_hasLibraryRoot;

    return MacSheet(
      child: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
              child: Text(
                widget.existing == null ? '添加监控目录' : '编辑监控目录',
                style: theme.textTheme.titleMedium,
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 16, 24, 10),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FormRow(
                      label: '连接',
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: PopupMenuButton<ConnectionId>(
                          key: const ValueKey('watch-conn-picker'),
                          tooltip: '选择连接',
                          initialValue: _connId,
                          onSelected: _selectConnection,
                          position: PopupMenuPosition.under,
                          itemBuilder: (_) => [
                            for (final c in widget.connections)
                              PopupMenuItem<ConnectionId>(
                                value: c.id,
                                height: 32,
                                child: Row(
                                  children: [
                                    Icon(
                                      connectionTypeIcon(c.type),
                                      size: 14,
                                      color: pColors.textMuted,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      '${c.name}（${connectionTypeLabel(c.type)}）',
                                    ),
                                  ],
                                ),
                              ),
                          ],
                          child: Container(
                            height: 31,
                            padding: const EdgeInsets.only(left: 10, right: 7),
                            decoration: BoxDecoration(
                              color: pColors.panel,
                              borderRadius: BorderRadius.circular(Radii.sm),
                              border: Border.all(
                                color: pColors.lineStrong,
                                width: hairline,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  connectionTypeIcon(conn.type),
                                  size: 13,
                                  color: pColors.textMuted,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${conn.name}（${connectionTypeLabel(conn.type)}）',
                                  style: const TextStyle(fontSize: 13),
                                ),
                                const SizedBox(width: 6),
                                Icon(
                                  CupertinoIcons.chevron_up_chevron_down,
                                  size: 11,
                                  color: pColors.textMuted,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                    FormRow(
                      label: '监控目录',
                      help: _browseHint ?? '支持填写下载完成目录路径，或点击下方收藏快捷填入',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: TextField(
                                  key: const ValueKey('watch-field-path'),
                                  controller: _path,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontFamily: monoFamily,
                                    fontFamilyFallback: [
                                      ...monoFallback,
                                      ...sansFallback,
                                    ],
                                  ),
                                  decoration: InputDecoration(
                                    hintText: '/下载/完成',
                                    errorText:
                                        _showErrors && _path.text.trim().isEmpty
                                        ? '请填写监控目录路径'
                                        : null,
                                  ),
                                ),
                              ),
                              if (_isLocal || widget.remoteLister != null) ...[
                                const SizedBox(width: 6),
                                OutlinedButton(
                                  key: const ValueKey('watch-browse-path'),
                                  onPressed: _browse,
                                  child: const Text('浏览…'),
                                ),
                              ],
                            ],
                          ),
                          if (quickPaths.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final fav in quickPaths)
                                  Hoverable(
                                    onTap: () =>
                                        setState(() => _path.text = fav),
                                    builder: (_, hover) => Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: hover
                                            ? pColors.selected
                                            : pColors.hover,
                                        borderRadius: BorderRadius.circular(
                                          Radii.sm,
                                        ),
                                        border: Border.all(
                                          color: pColors.line,
                                          width: hairline,
                                        ),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            CupertinoIcons.star,
                                            size: 11,
                                            color: pColors.textFaint,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            fav,
                                            style: TextStyle(
                                              fontSize: TypeScale.small,
                                              color: pColors.textMuted,
                                              fontFamily: monoFamily,
                                              fontFamilyFallback: [
                                                ...monoFallback,
                                                ...sansFallback,
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                    FormRow(
                      label: '检查频率',
                      child: _isLocal
                          ? Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                              decoration: BoxDecoration(
                                color: pColors.hover,
                                borderRadius: BorderRadius.circular(Radii.sm),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    CupertinoIcons.bolt,
                                    size: 13,
                                    color: pColors.success,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      '本地实时监听（变动后自动等待稳定）',
                                      style: TextStyle(
                                        fontSize: TypeScale.small,
                                        color: pColors.text,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          : Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final entry in _intervalOptions.entries)
                                  Hoverable(
                                    key: ValueKey(
                                      'watch-interval-${entry.key}',
                                    ),
                                    onTap: () =>
                                        setState(() => _interval = entry.key),
                                    builder: (_, hover) {
                                      final active = _interval == entry.key;
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: active
                                              ? pColors.selected
                                              : (hover
                                                    ? pColors.hover
                                                    : Colors.transparent),
                                          borderRadius: BorderRadius.circular(
                                            Radii.sm,
                                          ),
                                          border: Border.all(
                                            color: active
                                                ? pColors.lineStrong
                                                : pColors.line,
                                            width: hairline,
                                          ),
                                        ),
                                        child: Text(
                                          entry.value,
                                          style: TextStyle(
                                            fontSize: TypeScale.small,
                                            fontWeight: active
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            color: active
                                                ? pColors.text
                                                : pColors.textMuted,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                              ],
                            ),
                    ),
                    FormRow(
                      label: '整理模式',
                      help: modeWarning
                          ? '该连接尚未配置媒体库路径，请先在「来源」编辑连接填写媒体库，或选择「原地整理」'
                          : (_hasLibraryRoot &&
                                    _mode == OrganizeMode.moveToLibrary
                                ? '识别完成后将移动到：${conn.libraryRoot}'
                                : null),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Segmented<OrganizeMode>(
                          key: const ValueKey('watch-mode-segmented'),
                          options: const {
                            OrganizeMode.inPlace: '原地整理',
                            OrganizeMode.moveToLibrary: '移动到媒体库',
                          },
                          value: _mode,
                          onChanged: (m) => setState(() => _mode = m),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Panel(
                      framed: true,
                      color: pColors.canvas.withValues(alpha: 0.6),
                      child: Rows(
                        children: [
                          SettingRow(
                            title: '同时刮削 NFO 与海报',
                            caption: '整理新文件时自动写入 Kodi/VidHub 所需元数据与封面',
                            control: MacSwitch(
                              key: const ValueKey('watch-switch-scrape'),
                              value: _scrape,
                              onChanged: (v) => setState(() => _scrape = v),
                            ),
                          ),
                          SettingRow(
                            title: '高置信度自动执行',
                            caption:
                                '默认仅自动识别并进入「待确认」；开启后仅自动执行高置信且无冲突的文件，不自动删除任何文件',
                            control: MacSwitch(
                              key: const ValueKey('watch-switch-autorun'),
                              value: _autoRun,
                              onChanged: (v) => setState(() => _autoRun = v),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 22, 18),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('watch-rule-save'),
                    onPressed: modeWarning ? null : _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
