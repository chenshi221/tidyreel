import 'l10n.dart';

/// Translates user-facing messages, warnings, conflict reasons, and errors
/// emitted by `tidyreel_core` (which stays locale-independent with Chinese
/// canonical strings) into English when [l10n.isEn] is true.
String localizeCoreMessage(AppL10n l10n, String raw) {
  if (!l10n.isEn || raw.isEmpty) return raw;

  final exact = _exact[raw];
  if (exact != null) return exact;

  // Step failures: "<step>失败：<detail>"
  final stepFail = _stepFailRe.firstMatch(raw);
  if (stepFail != null) {
    final step = _stepNames[stepFail.group(1)!] ?? stepFail.group(1)!;
    final detail = localizeCoreMessage(l10n, stepFail.group(2)!);
    return '$step failed: $detail';
  }

  // Undo partial / full with notes: "已撤销(部分操作)（...）"
  final undone = _undoneNoteRe.firstMatch(raw);
  if (undone != null) {
    final partial = undone.group(1) != null;
    final noteRaw = undone.group(2);
    final note = noteRaw == null ? '' : ' (${_translateUndoNote(noteRaw)})';
    return partial ? 'Partially undone$note' : 'Undone$note';
  }

  // Undo progress: "正在撤销（a/b）"
  final undoing = _undoingRe.firstMatch(raw);
  if (undoing != null) {
    return 'Undoing (${undoing.group(1)}/${undoing.group(2)})';
  }

  // Importing count: "正在导入文件（已导入 N 个）"
  final importing = _importingCountRe.firstMatch(raw);
  if (importing != null) {
    final n = int.tryParse(importing.group(1)!) ?? 0;
    return 'Importing files ($n imported)';
  }

  // Recognizing count: "正在识别（共 N 个文件）"
  final recognizing = _recognizingCountRe.firstMatch(raw);
  if (recognizing != null) {
    final n = int.tryParse(recognizing.group(1)!) ?? 0;
    return 'Matching (${l10n.plural(n, 'file')})';
  }

  // Partial failure summary: "部分操作失败（N 项），其余已完成"
  final partialFail = _partialFailRe.firstMatch(raw);
  if (partialFail != null) {
    final n = int.tryParse(partialFail.group(1)!) ?? 0;
    return '${l10n.plural(n, 'operation')} failed; the rest completed';
  }

  // Selected paths missing: "所选路径不存在：..."
  if (raw.startsWith('所选路径不存在：')) {
    final rest = raw.substring('所选路径不存在：'.length).replaceAll('、', ', ');
    return 'Selected path not found: $rest';
  }

  // Conflict: N files mapped to same target
  final sameTarget = _sameTargetRe.firstMatch(raw);
  if (sameTarget != null) {
    return '${sameTarget.group(1)} files would be renamed to the same path';
  }

  // Recommended season split reason
  final splitReason = _splitReasonRe.firstMatch(raw);
  if (splitReason != null) {
    return 'Continuous absolute numbering (up to ep ${splitReason.group(1)}) '
        'exceeds TMDB Season 1 (${splitReason.group(2)} episodes); '
        'splitting across TMDB seasons is recommended';
  }

  // Task stage disallow error: "任务当前状态不允许此操作（<stage>）"
  final badStage = _badStageRe.firstMatch(raw);
  if (badStage != null) {
    final stage = _stageLabels[badStage.group(1)!] ?? badStage.group(1)!;
    return 'Action not allowed while task is $stage';
  }

  // TMDB errors
  final tmdbNonJson = _tmdbNonJsonRe.firstMatch(raw);
  if (tmdbNonJson != null) {
    return 'TMDB returned a non-JSON response (HTTP ${tmdbNonJson.group(1)}). '
        'Check your TMDB Base URL in Settings';
  }
  final tmdbCantConnect = _tmdbCantConnectRe.firstMatch(raw);
  if (tmdbCantConnect != null) {
    return 'Cannot connect to TMDB (${tmdbCantConnect.group(1)}). '
        'Configure a proxy Base URL in Settings if direct access is blocked';
  }
  final tmdbFailDetail = _tmdbFailDetailRe.firstMatch(raw);
  if (tmdbFailDetail != null) {
    return 'TMDB request failed (HTTP ${tmdbFailDetail.group(1)}): '
        '${tmdbFailDetail.group(2)}';
  }
  final tmdbFail = _tmdbFailRe.firstMatch(raw);
  if (tmdbFail != null) {
    return 'TMDB request failed (HTTP ${tmdbFail.group(1)})';
  }

  // Alist / WebDAV / Local / SMB / Executor errors
  final alistReq = _alistReqRe.firstMatch(raw);
  if (alistReq != null) {
    return 'Alist request failed (${alistReq.group(1)}): '
        '${localizeCoreMessage(l10n, alistReq.group(2)!)}';
  }
  final alistLogin = _alistLoginRe.firstMatch(raw);
  if (alistLogin != null) {
    return 'Alist sign-in failed: invalid username or password (${alistLogin.group(1)})';
  }
  final alistOpCode = _alistOpCodeRe.firstMatch(raw);
  if (alistOpCode != null) {
    final what = _translateAlistWhat(alistOpCode.group(1)!);
    final msg = alistOpCode.group(2);
    final code = alistOpCode.group(3)!;
    return msg != null
        ? '$what failed: $msg (code $code)'
        : '$what failed (code $code)';
  }
  final readFileHttp = _readFileHttpRe.firstMatch(raw);
  if (readFileHttp != null) {
    final prefix = readFileHttp.group(1) == '分段读取'
        ? 'Range read failed'
        : 'Read file failed';
    return '$prefix (${readFileHttp.group(2)}): HTTP ${readFileHttp.group(3)}';
  }
  final readFileErr = _readFileErrRe.firstMatch(raw);
  if (readFileErr != null) {
    final prefix = switch (readFileErr.group(1)) {
      '分段读取' => 'Range read failed',
      '上传' => 'Upload failed',
      _ => 'Read file failed',
    };
    return '$prefix (${readFileErr.group(2)}): '
        '${localizeCoreMessage(l10n, readFileErr.group(3)!)}';
  }
  final rangeUnsupported = _rangeUnsupportedRe.firstMatch(raw);
  if (rangeUnsupported != null) {
    return 'Server does not support range reads (${rangeUnsupported.group(1)}): HTTP 200';
  }
  final webdavHttp = _webdavHttpRe.firstMatch(raw);
  if (webdavHttp != null) {
    return 'WebDAV ${webdavHttp.group(1)} ${webdavHttp.group(2)} failed: '
        'HTTP ${webdavHttp.group(3)}';
  }
  final webdavOp = _webdavOpRe.firstMatch(raw);
  if (webdavOp != null) {
    final op = switch (webdavOp.group(1)) {
      '读取' => 'read',
      '分段读取' => 'range read',
      final m => m!,
    };
    return 'WebDAV $op ${webdavOp.group(2)} failed: '
        '${localizeCoreMessage(l10n, webdavOp.group(3)!)}';
  }
  final localOp = _localOpRe.firstMatch(raw);
  if (localOp != null) {
    return 'Local storage operation failed (${localOp.group(1)}): ${localOp.group(2)}';
  }
  final downloadErr = _downloadErrRe.firstMatch(raw);
  if (downloadErr != null) {
    return 'Download ${downloadErr.group(1)}: ${downloadErr.group(2)}';
  }
  final cantConnect = _cantConnectRe.firstMatch(raw);
  if (cantConnect != null) {
    return 'Cannot connect to server (${cantConnect.group(1)})';
  }

  // Connection diagnostics (sources_providers.dart)
  final connStartMissing = _connStartMissingRe.firstMatch(raw);
  if (connStartMissing != null) {
    return 'Server connected, but connection path "${connStartMissing.group(1)}" does not exist';
  }
  final connLibMissing = _connLibMissingRe.firstMatch(raw);
  if (connLibMissing != null) {
    return 'Server connected, but media library path "${connLibMissing.group(1)}" does not exist';
  }
  const alistDavHint =
      '\n提示：这看起来是 Alist / OpenList，它的 WebDAV 路径是 /dav；也可以把类型改成 Alist';
  if (raw.endsWith(alistDavHint)) {
    final head = raw.substring(0, raw.length - alistDavHint.length);
    return '${localizeCoreMessage(l10n, head)}\n'
        'Tip: this looks like Alist / OpenList. Its WebDAV path is /dav, or switch the connection type to Alist';
  }

  // Health scan progress: "已扫描 X 个目录 · Y 个文件"
  final healthProg = _healthProgRe.firstMatch(raw);
  if (healthProg != null) {
    final dirs = int.tryParse(healthProg.group(1)!) ?? 0;
    final files = int.tryParse(healthProg.group(2)!) ?? 0;
    return 'Scanned ${l10n.plural(dirs, 'folder')} · ${l10n.plural(files, 'file')}';
  }

  for (final entry in _prefixes.entries) {
    if (raw.startsWith(entry.key)) {
      final tail = raw.substring(entry.key.length);
      return '${entry.value}${localizeCoreMessage(l10n, tail)}';
    }
  }

  return raw;
}

String _translateUndoNote(String raw) {
  final parts = raw.split('，').map((part) {
    final fail = RegExp(r'^(\d+) 项失败$').firstMatch(part);
    if (fail != null) return '${fail.group(1)} failed';
    final skip = RegExp(r'^(\d+) 项已跳过$').firstMatch(part);
    if (skip != null) return '${skip.group(1)} skipped';
    return part;
  });
  return parts.join(', ');
}

String _translateAlistWhat(String what) {
  if (what == '登录') return 'Sign-in';
  if (what.startsWith('上传 ')) return 'Upload ${what.substring(3)}';
  return what;
}

const _stepNames = {
  '导入': 'Import',
  '识别': 'Matching',
  '生成计划': 'Planning',
  '执行': 'Execution',
};

const _stageLabels = {
  '导入中': 'importing',
  '识别中': 'matching',
  '待确认': 'awaiting review',
  '重命名文件中': 'renaming files',
  '整理文件夹中': 'organizing folders',
  '已完成': 'done',
  '部分失败': 'partially failed',
  '已取消': 'cancelled',
  '已撤销': 'undone',
  '已失败': 'failed',
};

const _exact = <String, String>{
  // Planner & review warnings
  '超出 TMDB 总集数': 'Exceeds TMDB total episode count',
  '识别置信度较低': 'Low parsing confidence',
  '片名匹配置信度较低': 'Low title match confidence',
  '季号无效': 'Invalid season number',
  '集号无效': 'Invalid episode number',
  '已存在，保留原文件': 'Already exists; keeping original file',
  '目标位置已存在同名文件或文件夹': 'A file or folder with the same name already exists',

  // Task manager status & errors
  '上次执行未开始，请重新确认': 'Previous run did not start; please review again',
  '正在导入文件': 'Importing files',
  '锚点识别完成，正在进行后续处理': 'Anchor match done; finishing up',
  '识别完成，请确认结果后继续执行': 'Matching complete; review results to continue',
  '正在重命名文件': 'Renaming files',
  '正在整理文件夹': 'Organizing folders',
  '正在刮削（写入元数据和海报）': 'Scraping (writing metadata and artwork)',
  '正在清理': 'Cleaning up',
  '正在重试失败的操作': 'Retrying failed operations',
  '整理完成': 'Organization complete',
  '已取消': 'Cancelled',
  '已撤销': 'Undone',
  '任务正在处理中': 'Task is currently busy',
  '任务尚未识别完成': 'Task has not finished matching yet',
  '正在更新整理计划，请稍后再试': 'Updating plan; please try again shortly',
  '存在冲突，无法执行': 'Resolve conflicts before running',
  '没有可执行的操作：请先勾选要整理的作品': 'Nothing to run: select at least one work first',
  '任务没有失败的操作': 'Task has no failed operations',
  '这个任务不能重试': 'This task cannot be retried',
  '任务正在进行，先取消再删除': 'Task is active; cancel it before deleting',
  '任务没有可撤销的操作': 'Task has no operations to undo',
  '任务正在撤销中': 'Task is already being undone',
  '不能将分组与自身合并': 'Cannot merge a group with itself',
  '拆分必须选择分组中的部分文件，且至少保留 1 个文件':
      'Select a subset of files to split while keeping at least 1 file',
  '请先在「设置」里填写 TMDB API key': 'Enter your TMDB API key in Settings first',

  // Storage & network friendly errors
  '文件或目录不存在': 'File or folder not found',
  '目标位置已存在同名文件或目录': 'Destination already exists',
  '认证失败，请检查账号或密码': 'Authentication failed; check username or password',
  '请求过于频繁，请稍后重试': 'Too many requests; please try again later',
  '网络连接失败': 'Network connection failed',
  '文件或目录正被占用': 'File or folder is in use',
  '存储访问出错': 'Storage access error',
  '参数无效': 'Invalid argument',
  '连接超时': 'Connection timed out',
  '发送请求超时': 'Send timed out',
  '服务器响应超时': 'Server response timed out',
  'HTTPS 证书校验失败': 'HTTPS certificate verification failed',
  '请求已取消': 'Request cancelled',
  '无法连接服务器': 'Cannot connect to server',
  '服务器返回了非 JSON 响应（HTTP 200），请检查 Alist 地址是否正确':
      'Server returned a non-JSON response (HTTP 200). Check your Alist URL',
  'Alist 登录失败：服务器未返回有效令牌': 'Alist sign-in failed: no valid token returned',
  '连接检测失败：服务器返回数据格式异常': 'Connection check failed: unexpected response format',
  '不支持分段读取': 'Range reads are not supported',
  '这个版本不支持 SMB': 'SMB is not supported in this build',

  // TMDB errors
  '连接 TMDB 超时，如无法直连请在设置中配置 TMDB 代理地址（Base URL）': 'Connection to TMDB timed out. Configure a proxy Base URL in Settings if needed',
  'TMDB HTTPS 证书校验失败，请检查代理或网络环境':
      'TMDB HTTPS certificate verification failed. Check your proxy or network',
  'TMDB 请求已取消': 'TMDB request cancelled',
  'TMDB API Key 无效或已过期，请在设置中检查':
      'TMDB API key is invalid or expired. Check it in Settings',
  'TMDB 请求过于频繁（HTTP 429），请稍后重试':
      'TMDB rate limit reached (HTTP 429). Please try again later',

  // Executor undo / skip reasons
  '删除无法撤销': 'Deleted files cannot be restored',
  '文件夹非空，已保留': 'Folder is not empty; kept',

  // Health scanner progress & cleanup reasons
  '正在准备扫描…': 'Preparing scan…',
  '正在加载目录列表…': 'Loading directory list…',
  '正在比对重复片源…': 'Comparing duplicate files…',
  '正在检查 NFO 与海报…': 'Checking NFO and artwork…',
  '正在扫描垃圾文件与空目录…': 'Scanning junk files and empty folders…',
  '体检完成': 'Health check complete',
  '系统隐藏垃圾': 'OS metadata file',
  '样片文件': 'Sample file',
  '广告 / 垃圾文件': 'Ad / junk file',
  '空目录': 'Empty folder',
};

const _prefixes = <String, String>{
  '执行出错：': 'Execution failed: ',
  '连接不存在：': 'Connection not found: ',
  '未找到任务：': 'Task not found: ',
  '未找到未分组文件：': 'Unassigned file not found: ',
  '未找到目标分组：': 'Target group not found: ',
  '未找到保留分组：': 'Target group not found: ',
  '未找到被合并分组：': 'Source group not found: ',
  '未找到分组：': 'Group not found: ',
  '文件不存在：': 'File not found: ',
  '文件已存在：': 'File already exists: ',
  '路径已存在且不是目录：': 'Path exists and is not a folder: ',
  '目标已存在，无法确认是否由本任务创建，已保留：':
      'Destination already exists and may not belong to this task; kept: ',
  '目标已存在：': 'Destination already exists: ',
  '目标已不存在：': 'Destination no longer exists: ',
  '目标文件名重复：': 'Duplicate target filename: ',
  '源文件不存在：': 'Source file not found: ',
  '原位置已被占用：': 'Original path is occupied: ',
  '依赖的操作失败：': 'Prerequisite operation failed: ',
  '路径超出根目录范围：': 'Path is outside the root folder: ',
  '目录不存在：': 'Folder not found: ',
  '源路径不存在：': 'Source path not found: ',
  '无效的文件名：': 'Invalid filename: ',
  '目标目录不存在：': 'Target folder not found: ',
  '路径不存在：': 'Path not found: ',
  '本地目录不存在：': 'Local folder not found: ',
  '地址应为 smb://主机/共享名：': 'Address should be smb://host/share: ',
  '用户名或密码错误（区分大小写）：': 'Invalid username or password (case-sensitive): ',
};

final _stepFailRe = RegExp(r'^(导入|识别|生成计划|执行)失败：(.*)$');
final _undoneNoteRe = RegExp(r'^已撤销(部分操作)?(?:（(.*)）)?$');
final _undoingRe = RegExp(r'^正在撤销（(\d+)/(\d+)）$');
final _importingCountRe = RegExp(r'^正在导入文件（已导入 (\d+) 个）$');
final _recognizingCountRe = RegExp(r'^正在识别（共 (\d+) 个文件）$');
final _partialFailRe = RegExp(r'^部分操作失败（(\d+) 项），其余已完成$');
final _sameTargetRe = RegExp(r'^有 (\d+) 个文件会被命名为同一个路径$');
final _splitReasonRe = RegExp(
  r'^本地为连续绝对集数（最大第 (\d+) 集），超出 TMDB 第 1 季（(\d+) 集），建议按 TMDB 季结构顺序拆多季$',
);
final _badStageRe = RegExp(r'^任务当前状态不允许此操作（(.*)）$');
final _tmdbNonJsonRe = RegExp(
  r'^TMDB 返回了非 JSON 响应（HTTP (\d+)），请检查 TMDB 代理地址（Base URL）是否正确$',
);
final _tmdbCantConnectRe = RegExp(
  r'^无法连接 TMDB（(.*)），如无法直连请在设置中配置 TMDB 代理地址（Base URL）$',
);
final _tmdbFailDetailRe = RegExp(r'^TMDB 请求失败（HTTP (\d+)）：(.*)$');
final _tmdbFailRe = RegExp(r'^TMDB 请求失败（HTTP (\d+)）$');
final _alistReqRe = RegExp(r'^Alist 请求失败（(.*?)）：(.*)$');
final _alistLoginRe = RegExp(r'^Alist 登录失败：用户名或密码错误（(.*)）$');
final _alistOpCodeRe = RegExp(r'^(.*?) 失败(?:：(.*?))?（code (\d+)）$');
final _readFileHttpRe = RegExp(r'^(分段读取|读取)文件失败（(.*?)）：HTTP (\d+)$');
final _readFileErrRe = RegExp(r'^(分段读取|读取|上传)文件失败（(.*?)）：(.*)$');
final _rangeUnsupportedRe = RegExp(r'^(?:WebDAV )?服务器不支持分段读取（(.*?)）：HTTP 200$');
final _webdavHttpRe = RegExp(r'^WebDAV (\S+) (.*?) 失败：HTTP (\d+)$');
final _webdavOpRe = RegExp(r'^WebDAV (读取|分段读取|\S+) (.*?) 失败：(.*)$');
final _localOpRe = RegExp(r'^本地存储操作失败（(.*?)）：(.*)$');
final _downloadErrRe = RegExp(r'^下载 (\S+)：(.*)$');
final _cantConnectRe = RegExp(r'^无法连接服务器（(.*)）$');
final _connStartMissingRe = RegExp(r'^服务器连接正常，但连接路径「(.*)」不存在$');
final _connLibMissingRe = RegExp(r'^服务器连接正常，但媒体库路径「(.*)」不存在$');
final _healthProgRe = RegExp(r'^已扫描 (\d+) 个目录 · (\d+) 个文件$');
