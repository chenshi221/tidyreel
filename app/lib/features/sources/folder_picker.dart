import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

import '../../l10n/l10n.dart';
import '../../ui/tokens.dart';
import '../../ui/widgets.dart';

/// Browse a server's folders and pick one; returns its path, or null.
Future<String?> showRemoteFolderPicker(
  BuildContext context, {
  required Future<List<RemoteEntry>> Function(String dir) list,
  String initial = '/',
  String? title,
}) => showDialog<String>(
  context: context,
  builder: (_) => _FolderPicker(
    list: list,
    initial: initial,
    title: title ?? context.tr('选择文件夹', 'Choose Folder'),
  ),
);

class _FolderPicker extends StatefulWidget {
  final Future<List<RemoteEntry>> Function(String dir) list;
  final String initial;
  final String title;

  const _FolderPicker({
    required this.list,
    required this.initial,
    required this.title,
  });

  @override
  State<_FolderPicker> createState() => _FolderPickerState();
}

class _FolderPickerState extends State<_FolderPicker> {
  late String _dir = normalizeDir(widget.initial);
  late Future<List<RemoteEntry>> _entries = _load(_dir);

  Future<List<RemoteEntry>> _load(String dir) async =>
      (await widget.list(dir)).where((e) => e.isDir).toList()
        ..sort((a, b) => a.name.compareTo(b.name));

  void _go(String dir) => setState(() {
    _dir = normalizeDir(dir);
    _entries = _load(_dir);
  });

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final segs = _dir.split('/').where((s) => s.isNotEmpty).toList();
    return MacSheet(
      child: SizedBox(
        width: 480,
        height: 460,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(widget.title, style: theme.textTheme.titleMedium),
              const SizedBox(height: 10),
              // Breadcrumbs: 根目录 › a › b
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  for (var i = 0; i <= segs.length; i++) ...[
                    if (i > 0)
                      Icon(
                        CupertinoIcons.chevron_right,
                        size: 10,
                        color: p.textFaint,
                      ),
                    TextButton(
                      onPressed: i == segs.length
                          ? null
                          : () => _go('/${segs.take(i).join('/')}'),
                      child: Text(i == 0 ? l10n.rootDir : segs[i - 1]),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Panel(
                  child: FutureBuilder(
                    future: _entries,
                    builder: (context, snap) {
                      if (snap.hasError) {
                        return EmptyState(
                          icon: CupertinoIcons.exclamationmark_triangle,
                          title: l10n.tr('无法读取文件夹', 'Unable to Read Folder'),
                          message: l10n.coreMessage('${snap.error}'),
                        );
                      }
                      final dirs = snap.data;
                      if (dirs == null) {
                        return const Center(child: Spinner(size: 20));
                      }
                      if (dirs.isEmpty) {
                        return EmptyState(
                          icon: CupertinoIcons.folder,
                          title: l10n.tr('没有子文件夹', 'No Subfolders'),
                          message: l10n.tr(
                            '可以直接选择当前文件夹',
                            'You can select the current folder directly',
                          ),
                        );
                      }
                      return ListView(
                        padding: const EdgeInsets.all(4),
                        children: [
                          for (final d in dirs)
                            Hoverable(
                              key: ValueKey('pick ${d.name}'),
                              onTap: () => _go(d.path),
                              builder: (context, hover) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: hover ? p.hover : Colors.transparent,
                                  borderRadius: BorderRadius.circular(Radii.sm),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      CupertinoIcons.folder_fill,
                                      size: 16,
                                      color: p.textMuted,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        d.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 13),
                                      ),
                                    ),
                                    Icon(
                                      CupertinoIcons.chevron_right,
                                      size: 12,
                                      color: p.textFaint,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _dir,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l10n.cancel),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    key: const ValueKey('pick-this'),
                    onPressed: () => Navigator.pop(context, _dir),
                    child: Text(l10n.tr('选择这个文件夹', 'Select Folder')),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
