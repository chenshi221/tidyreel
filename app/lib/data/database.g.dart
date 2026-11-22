// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $BatchesTable extends Batches with TableInfo<$BatchesTable, BatchRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BatchesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _taskIdMeta = const VerificationMeta('taskId');
  @override
  late final GeneratedColumn<String> taskId = GeneratedColumn<String>(
    'task_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, taskId, connectionId, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'batches';
  @override
  VerificationContext validateIntegrity(
    Insertable<BatchRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('task_id')) {
      context.handle(
        _taskIdMeta,
        taskId.isAcceptableOrUnknown(data['task_id']!, _taskIdMeta),
      );
    } else if (isInserting) {
      context.missing(_taskIdMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BatchRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BatchRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      taskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}task_id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $BatchesTable createAlias(String alias) {
    return $BatchesTable(attachedDatabase, alias);
  }
}

class BatchRow extends DataClass implements Insertable<BatchRow> {
  final String id;
  final String taskId;
  final String connectionId;
  final DateTime createdAt;
  const BatchRow({
    required this.id,
    required this.taskId,
    required this.connectionId,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['task_id'] = Variable<String>(taskId);
    map['connection_id'] = Variable<String>(connectionId);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  BatchesCompanion toCompanion(bool nullToAbsent) {
    return BatchesCompanion(
      id: Value(id),
      taskId: Value(taskId),
      connectionId: Value(connectionId),
      createdAt: Value(createdAt),
    );
  }

  factory BatchRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BatchRow(
      id: serializer.fromJson<String>(json['id']),
      taskId: serializer.fromJson<String>(json['taskId']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'taskId': serializer.toJson<String>(taskId),
      'connectionId': serializer.toJson<String>(connectionId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  BatchRow copyWith({
    String? id,
    String? taskId,
    String? connectionId,
    DateTime? createdAt,
  }) => BatchRow(
    id: id ?? this.id,
    taskId: taskId ?? this.taskId,
    connectionId: connectionId ?? this.connectionId,
    createdAt: createdAt ?? this.createdAt,
  );
  BatchRow copyWithCompanion(BatchesCompanion data) {
    return BatchRow(
      id: data.id.present ? data.id.value : this.id,
      taskId: data.taskId.present ? data.taskId.value : this.taskId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BatchRow(')
          ..write('id: $id, ')
          ..write('taskId: $taskId, ')
          ..write('connectionId: $connectionId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, taskId, connectionId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BatchRow &&
          other.id == this.id &&
          other.taskId == this.taskId &&
          other.connectionId == this.connectionId &&
          other.createdAt == this.createdAt);
}

class BatchesCompanion extends UpdateCompanion<BatchRow> {
  final Value<String> id;
  final Value<String> taskId;
  final Value<String> connectionId;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const BatchesCompanion({
    this.id = const Value.absent(),
    this.taskId = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BatchesCompanion.insert({
    required String id,
    required String taskId,
    required String connectionId,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       taskId = Value(taskId),
       connectionId = Value(connectionId),
       createdAt = Value(createdAt);
  static Insertable<BatchRow> custom({
    Expression<String>? id,
    Expression<String>? taskId,
    Expression<String>? connectionId,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (taskId != null) 'task_id': taskId,
      if (connectionId != null) 'connection_id': connectionId,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BatchesCompanion copyWith({
    Value<String>? id,
    Value<String>? taskId,
    Value<String>? connectionId,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return BatchesCompanion(
      id: id ?? this.id,
      taskId: taskId ?? this.taskId,
      connectionId: connectionId ?? this.connectionId,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (taskId.present) {
      map['task_id'] = Variable<String>(taskId.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BatchesCompanion(')
          ..write('id: $id, ')
          ..write('taskId: $taskId, ')
          ..write('connectionId: $connectionId, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $HistoryRecordsTable extends HistoryRecords
    with TableInfo<$HistoryRecordsTable, HistoryRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $HistoryRecordsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _batchIdMeta = const VerificationMeta(
    'batchId',
  );
  @override
  late final GeneratedColumn<String> batchId = GeneratedColumn<String>(
    'batch_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES batches (id)',
    ),
  );
  static const VerificationMeta _opIdMeta = const VerificationMeta('opId');
  @override
  late final GeneratedColumn<String> opId = GeneratedColumn<String>(
    'op_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
    'seq',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _phaseMeta = const VerificationMeta('phase');
  @override
  late final GeneratedColumn<String> phase = GeneratedColumn<String>(
    'phase',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _srcMeta = const VerificationMeta('src');
  @override
  late final GeneratedColumn<String> src = GeneratedColumn<String>(
    'src',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dstMeta = const VerificationMeta('dst');
  @override
  late final GeneratedColumn<String> dst = GeneratedColumn<String>(
    'dst',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _groupIdMeta = const VerificationMeta(
    'groupId',
  );
  @override
  late final GeneratedColumn<String> groupId = GeneratedColumn<String>(
    'group_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _selectedMeta = const VerificationMeta(
    'selected',
  );
  @override
  late final GeneratedColumn<bool> selected = GeneratedColumn<bool>(
    'selected',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("selected" IN (0, 1))',
    ),
  );
  static const VerificationMeta _warningMeta = const VerificationMeta(
    'warning',
  );
  @override
  late final GeneratedColumn<String> warning = GeneratedColumn<String>(
    'warning',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    batchId,
    opId,
    seq,
    kind,
    phase,
    src,
    dst,
    groupId,
    selected,
    warning,
    status,
    error,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'history_records';
  @override
  VerificationContext validateIntegrity(
    Insertable<HistoryRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('batch_id')) {
      context.handle(
        _batchIdMeta,
        batchId.isAcceptableOrUnknown(data['batch_id']!, _batchIdMeta),
      );
    } else if (isInserting) {
      context.missing(_batchIdMeta);
    }
    if (data.containsKey('op_id')) {
      context.handle(
        _opIdMeta,
        opId.isAcceptableOrUnknown(data['op_id']!, _opIdMeta),
      );
    } else if (isInserting) {
      context.missing(_opIdMeta);
    }
    if (data.containsKey('seq')) {
      context.handle(
        _seqMeta,
        seq.isAcceptableOrUnknown(data['seq']!, _seqMeta),
      );
    } else if (isInserting) {
      context.missing(_seqMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('phase')) {
      context.handle(
        _phaseMeta,
        phase.isAcceptableOrUnknown(data['phase']!, _phaseMeta),
      );
    } else if (isInserting) {
      context.missing(_phaseMeta);
    }
    if (data.containsKey('src')) {
      context.handle(
        _srcMeta,
        src.isAcceptableOrUnknown(data['src']!, _srcMeta),
      );
    } else if (isInserting) {
      context.missing(_srcMeta);
    }
    if (data.containsKey('dst')) {
      context.handle(
        _dstMeta,
        dst.isAcceptableOrUnknown(data['dst']!, _dstMeta),
      );
    } else if (isInserting) {
      context.missing(_dstMeta);
    }
    if (data.containsKey('group_id')) {
      context.handle(
        _groupIdMeta,
        groupId.isAcceptableOrUnknown(data['group_id']!, _groupIdMeta),
      );
    }
    if (data.containsKey('selected')) {
      context.handle(
        _selectedMeta,
        selected.isAcceptableOrUnknown(data['selected']!, _selectedMeta),
      );
    } else if (isInserting) {
      context.missing(_selectedMeta);
    }
    if (data.containsKey('warning')) {
      context.handle(
        _warningMeta,
        warning.isAcceptableOrUnknown(data['warning']!, _warningMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('error')) {
      context.handle(
        _errorMeta,
        error.isAcceptableOrUnknown(data['error']!, _errorMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {batchId, opId};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {batchId, seq},
  ];
  @override
  HistoryRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return HistoryRow(
      batchId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}batch_id'],
      )!,
      opId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}op_id'],
      )!,
      seq: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seq'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      phase: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}phase'],
      )!,
      src: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}src'],
      )!,
      dst: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dst'],
      )!,
      groupId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}group_id'],
      ),
      selected: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}selected'],
      )!,
      warning: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}warning'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      error: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error'],
      ),
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $HistoryRecordsTable createAlias(String alias) {
    return $HistoryRecordsTable(attachedDatabase, alias);
  }
}

class HistoryRow extends DataClass implements Insertable<HistoryRow> {
  final String batchId;
  final String opId;

  /// Position in the batch; undo walks it backwards.
  final int seq;
  final String kind;
  final String phase;
  final String src;
  final String dst;
  final String? groupId;
  final bool selected;
  final String? warning;
  final String status;
  final String? error;
  final DateTime updatedAt;
  const HistoryRow({
    required this.batchId,
    required this.opId,
    required this.seq,
    required this.kind,
    required this.phase,
    required this.src,
    required this.dst,
    this.groupId,
    required this.selected,
    this.warning,
    required this.status,
    this.error,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['batch_id'] = Variable<String>(batchId);
    map['op_id'] = Variable<String>(opId);
    map['seq'] = Variable<int>(seq);
    map['kind'] = Variable<String>(kind);
    map['phase'] = Variable<String>(phase);
    map['src'] = Variable<String>(src);
    map['dst'] = Variable<String>(dst);
    if (!nullToAbsent || groupId != null) {
      map['group_id'] = Variable<String>(groupId);
    }
    map['selected'] = Variable<bool>(selected);
    if (!nullToAbsent || warning != null) {
      map['warning'] = Variable<String>(warning);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  HistoryRecordsCompanion toCompanion(bool nullToAbsent) {
    return HistoryRecordsCompanion(
      batchId: Value(batchId),
      opId: Value(opId),
      seq: Value(seq),
      kind: Value(kind),
      phase: Value(phase),
      src: Value(src),
      dst: Value(dst),
      groupId: groupId == null && nullToAbsent
          ? const Value.absent()
          : Value(groupId),
      selected: Value(selected),
      warning: warning == null && nullToAbsent
          ? const Value.absent()
          : Value(warning),
      status: Value(status),
      error: error == null && nullToAbsent
          ? const Value.absent()
          : Value(error),
      updatedAt: Value(updatedAt),
    );
  }

  factory HistoryRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return HistoryRow(
      batchId: serializer.fromJson<String>(json['batchId']),
      opId: serializer.fromJson<String>(json['opId']),
      seq: serializer.fromJson<int>(json['seq']),
      kind: serializer.fromJson<String>(json['kind']),
      phase: serializer.fromJson<String>(json['phase']),
      src: serializer.fromJson<String>(json['src']),
      dst: serializer.fromJson<String>(json['dst']),
      groupId: serializer.fromJson<String?>(json['groupId']),
      selected: serializer.fromJson<bool>(json['selected']),
      warning: serializer.fromJson<String?>(json['warning']),
      status: serializer.fromJson<String>(json['status']),
      error: serializer.fromJson<String?>(json['error']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'batchId': serializer.toJson<String>(batchId),
      'opId': serializer.toJson<String>(opId),
      'seq': serializer.toJson<int>(seq),
      'kind': serializer.toJson<String>(kind),
      'phase': serializer.toJson<String>(phase),
      'src': serializer.toJson<String>(src),
      'dst': serializer.toJson<String>(dst),
      'groupId': serializer.toJson<String?>(groupId),
      'selected': serializer.toJson<bool>(selected),
      'warning': serializer.toJson<String?>(warning),
      'status': serializer.toJson<String>(status),
      'error': serializer.toJson<String?>(error),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  HistoryRow copyWith({
    String? batchId,
    String? opId,
    int? seq,
    String? kind,
    String? phase,
    String? src,
    String? dst,
    Value<String?> groupId = const Value.absent(),
    bool? selected,
    Value<String?> warning = const Value.absent(),
    String? status,
    Value<String?> error = const Value.absent(),
    DateTime? updatedAt,
  }) => HistoryRow(
    batchId: batchId ?? this.batchId,
    opId: opId ?? this.opId,
    seq: seq ?? this.seq,
    kind: kind ?? this.kind,
    phase: phase ?? this.phase,
    src: src ?? this.src,
    dst: dst ?? this.dst,
    groupId: groupId.present ? groupId.value : this.groupId,
    selected: selected ?? this.selected,
    warning: warning.present ? warning.value : this.warning,
    status: status ?? this.status,
    error: error.present ? error.value : this.error,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  HistoryRow copyWithCompanion(HistoryRecordsCompanion data) {
    return HistoryRow(
      batchId: data.batchId.present ? data.batchId.value : this.batchId,
      opId: data.opId.present ? data.opId.value : this.opId,
      seq: data.seq.present ? data.seq.value : this.seq,
      kind: data.kind.present ? data.kind.value : this.kind,
      phase: data.phase.present ? data.phase.value : this.phase,
      src: data.src.present ? data.src.value : this.src,
      dst: data.dst.present ? data.dst.value : this.dst,
      groupId: data.groupId.present ? data.groupId.value : this.groupId,
      selected: data.selected.present ? data.selected.value : this.selected,
      warning: data.warning.present ? data.warning.value : this.warning,
      status: data.status.present ? data.status.value : this.status,
      error: data.error.present ? data.error.value : this.error,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('HistoryRow(')
          ..write('batchId: $batchId, ')
          ..write('opId: $opId, ')
          ..write('seq: $seq, ')
          ..write('kind: $kind, ')
          ..write('phase: $phase, ')
          ..write('src: $src, ')
          ..write('dst: $dst, ')
          ..write('groupId: $groupId, ')
          ..write('selected: $selected, ')
          ..write('warning: $warning, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    batchId,
    opId,
    seq,
    kind,
    phase,
    src,
    dst,
    groupId,
    selected,
    warning,
    status,
    error,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is HistoryRow &&
          other.batchId == this.batchId &&
          other.opId == this.opId &&
          other.seq == this.seq &&
          other.kind == this.kind &&
          other.phase == this.phase &&
          other.src == this.src &&
          other.dst == this.dst &&
          other.groupId == this.groupId &&
          other.selected == this.selected &&
          other.warning == this.warning &&
          other.status == this.status &&
          other.error == this.error &&
          other.updatedAt == this.updatedAt);
}

class HistoryRecordsCompanion extends UpdateCompanion<HistoryRow> {
  final Value<String> batchId;
  final Value<String> opId;
  final Value<int> seq;
  final Value<String> kind;
  final Value<String> phase;
  final Value<String> src;
  final Value<String> dst;
  final Value<String?> groupId;
  final Value<bool> selected;
  final Value<String?> warning;
  final Value<String> status;
  final Value<String?> error;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const HistoryRecordsCompanion({
    this.batchId = const Value.absent(),
    this.opId = const Value.absent(),
    this.seq = const Value.absent(),
    this.kind = const Value.absent(),
    this.phase = const Value.absent(),
    this.src = const Value.absent(),
    this.dst = const Value.absent(),
    this.groupId = const Value.absent(),
    this.selected = const Value.absent(),
    this.warning = const Value.absent(),
    this.status = const Value.absent(),
    this.error = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  HistoryRecordsCompanion.insert({
    required String batchId,
    required String opId,
    required int seq,
    required String kind,
    required String phase,
    required String src,
    required String dst,
    this.groupId = const Value.absent(),
    required bool selected,
    this.warning = const Value.absent(),
    required String status,
    this.error = const Value.absent(),
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : batchId = Value(batchId),
       opId = Value(opId),
       seq = Value(seq),
       kind = Value(kind),
       phase = Value(phase),
       src = Value(src),
       dst = Value(dst),
       selected = Value(selected),
       status = Value(status),
       updatedAt = Value(updatedAt);
  static Insertable<HistoryRow> custom({
    Expression<String>? batchId,
    Expression<String>? opId,
    Expression<int>? seq,
    Expression<String>? kind,
    Expression<String>? phase,
    Expression<String>? src,
    Expression<String>? dst,
    Expression<String>? groupId,
    Expression<bool>? selected,
    Expression<String>? warning,
    Expression<String>? status,
    Expression<String>? error,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (batchId != null) 'batch_id': batchId,
      if (opId != null) 'op_id': opId,
      if (seq != null) 'seq': seq,
      if (kind != null) 'kind': kind,
      if (phase != null) 'phase': phase,
      if (src != null) 'src': src,
      if (dst != null) 'dst': dst,
      if (groupId != null) 'group_id': groupId,
      if (selected != null) 'selected': selected,
      if (warning != null) 'warning': warning,
      if (status != null) 'status': status,
      if (error != null) 'error': error,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  HistoryRecordsCompanion copyWith({
    Value<String>? batchId,
    Value<String>? opId,
    Value<int>? seq,
    Value<String>? kind,
    Value<String>? phase,
    Value<String>? src,
    Value<String>? dst,
    Value<String?>? groupId,
    Value<bool>? selected,
    Value<String?>? warning,
    Value<String>? status,
    Value<String?>? error,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return HistoryRecordsCompanion(
      batchId: batchId ?? this.batchId,
      opId: opId ?? this.opId,
      seq: seq ?? this.seq,
      kind: kind ?? this.kind,
      phase: phase ?? this.phase,
      src: src ?? this.src,
      dst: dst ?? this.dst,
      groupId: groupId ?? this.groupId,
      selected: selected ?? this.selected,
      warning: warning ?? this.warning,
      status: status ?? this.status,
      error: error ?? this.error,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (batchId.present) {
      map['batch_id'] = Variable<String>(batchId.value);
    }
    if (opId.present) {
      map['op_id'] = Variable<String>(opId.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (phase.present) {
      map['phase'] = Variable<String>(phase.value);
    }
    if (src.present) {
      map['src'] = Variable<String>(src.value);
    }
    if (dst.present) {
      map['dst'] = Variable<String>(dst.value);
    }
    if (groupId.present) {
      map['group_id'] = Variable<String>(groupId.value);
    }
    if (selected.present) {
      map['selected'] = Variable<bool>(selected.value);
    }
    if (warning.present) {
      map['warning'] = Variable<String>(warning.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('HistoryRecordsCompanion(')
          ..write('batchId: $batchId, ')
          ..write('opId: $opId, ')
          ..write('seq: $seq, ')
          ..write('kind: $kind, ')
          ..write('phase: $phase, ')
          ..write('src: $src, ')
          ..write('dst: $dst, ')
          ..write('groupId: $groupId, ')
          ..write('selected: $selected, ')
          ..write('warning: $warning, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TasksTable extends Tasks with TableInfo<$TasksTable, TaskRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TasksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathsJsonMeta = const VerificationMeta(
    'pathsJson',
  );
  @override
  late final GeneratedColumn<String> pathsJson = GeneratedColumn<String>(
    'paths_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scrapeMeta = const VerificationMeta('scrape');
  @override
  late final GeneratedColumn<bool> scrape = GeneratedColumn<bool>(
    'scrape',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scrape" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _scrapeOnlyMeta = const VerificationMeta(
    'scrapeOnly',
  );
  @override
  late final GeneratedColumn<bool> scrapeOnly = GeneratedColumn<bool>(
    'scrape_only',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scrape_only" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _stageMeta = const VerificationMeta('stage');
  @override
  late final GeneratedColumn<String> stage = GeneratedColumn<String>(
    'stage',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _messageMeta = const VerificationMeta(
    'message',
  );
  @override
  late final GeneratedColumn<String> message = GeneratedColumn<String>(
    'message',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _importedCountMeta = const VerificationMeta(
    'importedCount',
  );
  @override
  late final GeneratedColumn<int> importedCount = GeneratedColumn<int>(
    'imported_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _videoCountMeta = const VerificationMeta(
    'videoCount',
  );
  @override
  late final GeneratedColumn<int> videoCount = GeneratedColumn<int>(
    'video_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _folderCountMeta = const VerificationMeta(
    'folderCount',
  );
  @override
  late final GeneratedColumn<int> folderCount = GeneratedColumn<int>(
    'folder_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _subtitleCountMeta = const VerificationMeta(
    'subtitleCount',
  );
  @override
  late final GeneratedColumn<int> subtitleCount = GeneratedColumn<int>(
    'subtitle_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<double> progress = GeneratedColumn<double>(
    'progress',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _batchIdMeta = const VerificationMeta(
    'batchId',
  );
  @override
  late final GeneratedColumn<String> batchId = GeneratedColumn<String>(
    'batch_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scanJsonMeta = const VerificationMeta(
    'scanJson',
  );
  @override
  late final GeneratedColumn<String> scanJson = GeneratedColumn<String>(
    'scan_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _decisionsJsonMeta = const VerificationMeta(
    'decisionsJson',
  );
  @override
  late final GeneratedColumn<String> decisionsJson = GeneratedColumn<String>(
    'decisions_json',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    connectionId,
    pathsJson,
    mode,
    scrape,
    scrapeOnly,
    stage,
    message,
    importedCount,
    videoCount,
    folderCount,
    subtitleCount,
    progress,
    batchId,
    createdAt,
    scanJson,
    decisionsJson,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tasks';
  @override
  VerificationContext validateIntegrity(
    Insertable<TaskRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('paths_json')) {
      context.handle(
        _pathsJsonMeta,
        pathsJson.isAcceptableOrUnknown(data['paths_json']!, _pathsJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_pathsJsonMeta);
    }
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    } else if (isInserting) {
      context.missing(_modeMeta);
    }
    if (data.containsKey('scrape')) {
      context.handle(
        _scrapeMeta,
        scrape.isAcceptableOrUnknown(data['scrape']!, _scrapeMeta),
      );
    }
    if (data.containsKey('scrape_only')) {
      context.handle(
        _scrapeOnlyMeta,
        scrapeOnly.isAcceptableOrUnknown(data['scrape_only']!, _scrapeOnlyMeta),
      );
    }
    if (data.containsKey('stage')) {
      context.handle(
        _stageMeta,
        stage.isAcceptableOrUnknown(data['stage']!, _stageMeta),
      );
    } else if (isInserting) {
      context.missing(_stageMeta);
    }
    if (data.containsKey('message')) {
      context.handle(
        _messageMeta,
        message.isAcceptableOrUnknown(data['message']!, _messageMeta),
      );
    } else if (isInserting) {
      context.missing(_messageMeta);
    }
    if (data.containsKey('imported_count')) {
      context.handle(
        _importedCountMeta,
        importedCount.isAcceptableOrUnknown(
          data['imported_count']!,
          _importedCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_importedCountMeta);
    }
    if (data.containsKey('video_count')) {
      context.handle(
        _videoCountMeta,
        videoCount.isAcceptableOrUnknown(data['video_count']!, _videoCountMeta),
      );
    } else if (isInserting) {
      context.missing(_videoCountMeta);
    }
    if (data.containsKey('folder_count')) {
      context.handle(
        _folderCountMeta,
        folderCount.isAcceptableOrUnknown(
          data['folder_count']!,
          _folderCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_folderCountMeta);
    }
    if (data.containsKey('subtitle_count')) {
      context.handle(
        _subtitleCountMeta,
        subtitleCount.isAcceptableOrUnknown(
          data['subtitle_count']!,
          _subtitleCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_subtitleCountMeta);
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    }
    if (data.containsKey('batch_id')) {
      context.handle(
        _batchIdMeta,
        batchId.isAcceptableOrUnknown(data['batch_id']!, _batchIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('scan_json')) {
      context.handle(
        _scanJsonMeta,
        scanJson.isAcceptableOrUnknown(data['scan_json']!, _scanJsonMeta),
      );
    }
    if (data.containsKey('decisions_json')) {
      context.handle(
        _decisionsJsonMeta,
        decisionsJson.isAcceptableOrUnknown(
          data['decisions_json']!,
          _decisionsJsonMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TaskRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TaskRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      pathsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}paths_json'],
      )!,
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      scrape: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scrape'],
      )!,
      scrapeOnly: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scrape_only'],
      )!,
      stage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}stage'],
      )!,
      message: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}message'],
      )!,
      importedCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}imported_count'],
      )!,
      videoCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}video_count'],
      )!,
      folderCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}folder_count'],
      )!,
      subtitleCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}subtitle_count'],
      )!,
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}progress'],
      ),
      batchId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}batch_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      scanJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}scan_json'],
      ),
      decisionsJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}decisions_json'],
      ),
    );
  }

  @override
  $TasksTable createAlias(String alias) {
    return $TasksTable(attachedDatabase, alias);
  }
}

class TaskRow extends DataClass implements Insertable<TaskRow> {
  final String id;
  final String connectionId;
  final String pathsJson;
  final String mode;
  final bool scrape;
  final bool scrapeOnly;
  final String stage;
  final String message;
  final int importedCount;
  final int videoCount;
  final int folderCount;
  final int subtitleCount;
  final double? progress;
  final String? batchId;
  final DateTime createdAt;

  /// TaskReview parts, as JSON (see codec.dart). Null until recognition finished.
  final String? scanJson;
  final String? decisionsJson;
  const TaskRow({
    required this.id,
    required this.connectionId,
    required this.pathsJson,
    required this.mode,
    required this.scrape,
    required this.scrapeOnly,
    required this.stage,
    required this.message,
    required this.importedCount,
    required this.videoCount,
    required this.folderCount,
    required this.subtitleCount,
    this.progress,
    this.batchId,
    required this.createdAt,
    this.scanJson,
    this.decisionsJson,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['connection_id'] = Variable<String>(connectionId);
    map['paths_json'] = Variable<String>(pathsJson);
    map['mode'] = Variable<String>(mode);
    map['scrape'] = Variable<bool>(scrape);
    map['scrape_only'] = Variable<bool>(scrapeOnly);
    map['stage'] = Variable<String>(stage);
    map['message'] = Variable<String>(message);
    map['imported_count'] = Variable<int>(importedCount);
    map['video_count'] = Variable<int>(videoCount);
    map['folder_count'] = Variable<int>(folderCount);
    map['subtitle_count'] = Variable<int>(subtitleCount);
    if (!nullToAbsent || progress != null) {
      map['progress'] = Variable<double>(progress);
    }
    if (!nullToAbsent || batchId != null) {
      map['batch_id'] = Variable<String>(batchId);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || scanJson != null) {
      map['scan_json'] = Variable<String>(scanJson);
    }
    if (!nullToAbsent || decisionsJson != null) {
      map['decisions_json'] = Variable<String>(decisionsJson);
    }
    return map;
  }

  TasksCompanion toCompanion(bool nullToAbsent) {
    return TasksCompanion(
      id: Value(id),
      connectionId: Value(connectionId),
      pathsJson: Value(pathsJson),
      mode: Value(mode),
      scrape: Value(scrape),
      scrapeOnly: Value(scrapeOnly),
      stage: Value(stage),
      message: Value(message),
      importedCount: Value(importedCount),
      videoCount: Value(videoCount),
      folderCount: Value(folderCount),
      subtitleCount: Value(subtitleCount),
      progress: progress == null && nullToAbsent
          ? const Value.absent()
          : Value(progress),
      batchId: batchId == null && nullToAbsent
          ? const Value.absent()
          : Value(batchId),
      createdAt: Value(createdAt),
      scanJson: scanJson == null && nullToAbsent
          ? const Value.absent()
          : Value(scanJson),
      decisionsJson: decisionsJson == null && nullToAbsent
          ? const Value.absent()
          : Value(decisionsJson),
    );
  }

  factory TaskRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TaskRow(
      id: serializer.fromJson<String>(json['id']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      pathsJson: serializer.fromJson<String>(json['pathsJson']),
      mode: serializer.fromJson<String>(json['mode']),
      scrape: serializer.fromJson<bool>(json['scrape']),
      scrapeOnly: serializer.fromJson<bool>(json['scrapeOnly']),
      stage: serializer.fromJson<String>(json['stage']),
      message: serializer.fromJson<String>(json['message']),
      importedCount: serializer.fromJson<int>(json['importedCount']),
      videoCount: serializer.fromJson<int>(json['videoCount']),
      folderCount: serializer.fromJson<int>(json['folderCount']),
      subtitleCount: serializer.fromJson<int>(json['subtitleCount']),
      progress: serializer.fromJson<double?>(json['progress']),
      batchId: serializer.fromJson<String?>(json['batchId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      scanJson: serializer.fromJson<String?>(json['scanJson']),
      decisionsJson: serializer.fromJson<String?>(json['decisionsJson']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'connectionId': serializer.toJson<String>(connectionId),
      'pathsJson': serializer.toJson<String>(pathsJson),
      'mode': serializer.toJson<String>(mode),
      'scrape': serializer.toJson<bool>(scrape),
      'scrapeOnly': serializer.toJson<bool>(scrapeOnly),
      'stage': serializer.toJson<String>(stage),
      'message': serializer.toJson<String>(message),
      'importedCount': serializer.toJson<int>(importedCount),
      'videoCount': serializer.toJson<int>(videoCount),
      'folderCount': serializer.toJson<int>(folderCount),
      'subtitleCount': serializer.toJson<int>(subtitleCount),
      'progress': serializer.toJson<double?>(progress),
      'batchId': serializer.toJson<String?>(batchId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'scanJson': serializer.toJson<String?>(scanJson),
      'decisionsJson': serializer.toJson<String?>(decisionsJson),
    };
  }

  TaskRow copyWith({
    String? id,
    String? connectionId,
    String? pathsJson,
    String? mode,
    bool? scrape,
    bool? scrapeOnly,
    String? stage,
    String? message,
    int? importedCount,
    int? videoCount,
    int? folderCount,
    int? subtitleCount,
    Value<double?> progress = const Value.absent(),
    Value<String?> batchId = const Value.absent(),
    DateTime? createdAt,
    Value<String?> scanJson = const Value.absent(),
    Value<String?> decisionsJson = const Value.absent(),
  }) => TaskRow(
    id: id ?? this.id,
    connectionId: connectionId ?? this.connectionId,
    pathsJson: pathsJson ?? this.pathsJson,
    mode: mode ?? this.mode,
    scrape: scrape ?? this.scrape,
    scrapeOnly: scrapeOnly ?? this.scrapeOnly,
    stage: stage ?? this.stage,
    message: message ?? this.message,
    importedCount: importedCount ?? this.importedCount,
    videoCount: videoCount ?? this.videoCount,
    folderCount: folderCount ?? this.folderCount,
    subtitleCount: subtitleCount ?? this.subtitleCount,
    progress: progress.present ? progress.value : this.progress,
    batchId: batchId.present ? batchId.value : this.batchId,
    createdAt: createdAt ?? this.createdAt,
    scanJson: scanJson.present ? scanJson.value : this.scanJson,
    decisionsJson: decisionsJson.present
        ? decisionsJson.value
        : this.decisionsJson,
  );
  TaskRow copyWithCompanion(TasksCompanion data) {
    return TaskRow(
      id: data.id.present ? data.id.value : this.id,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      pathsJson: data.pathsJson.present ? data.pathsJson.value : this.pathsJson,
      mode: data.mode.present ? data.mode.value : this.mode,
      scrape: data.scrape.present ? data.scrape.value : this.scrape,
      scrapeOnly: data.scrapeOnly.present
          ? data.scrapeOnly.value
          : this.scrapeOnly,
      stage: data.stage.present ? data.stage.value : this.stage,
      message: data.message.present ? data.message.value : this.message,
      importedCount: data.importedCount.present
          ? data.importedCount.value
          : this.importedCount,
      videoCount: data.videoCount.present
          ? data.videoCount.value
          : this.videoCount,
      folderCount: data.folderCount.present
          ? data.folderCount.value
          : this.folderCount,
      subtitleCount: data.subtitleCount.present
          ? data.subtitleCount.value
          : this.subtitleCount,
      progress: data.progress.present ? data.progress.value : this.progress,
      batchId: data.batchId.present ? data.batchId.value : this.batchId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      scanJson: data.scanJson.present ? data.scanJson.value : this.scanJson,
      decisionsJson: data.decisionsJson.present
          ? data.decisionsJson.value
          : this.decisionsJson,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TaskRow(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('pathsJson: $pathsJson, ')
          ..write('mode: $mode, ')
          ..write('scrape: $scrape, ')
          ..write('scrapeOnly: $scrapeOnly, ')
          ..write('stage: $stage, ')
          ..write('message: $message, ')
          ..write('importedCount: $importedCount, ')
          ..write('videoCount: $videoCount, ')
          ..write('folderCount: $folderCount, ')
          ..write('subtitleCount: $subtitleCount, ')
          ..write('progress: $progress, ')
          ..write('batchId: $batchId, ')
          ..write('createdAt: $createdAt, ')
          ..write('scanJson: $scanJson, ')
          ..write('decisionsJson: $decisionsJson')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    connectionId,
    pathsJson,
    mode,
    scrape,
    scrapeOnly,
    stage,
    message,
    importedCount,
    videoCount,
    folderCount,
    subtitleCount,
    progress,
    batchId,
    createdAt,
    scanJson,
    decisionsJson,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TaskRow &&
          other.id == this.id &&
          other.connectionId == this.connectionId &&
          other.pathsJson == this.pathsJson &&
          other.mode == this.mode &&
          other.scrape == this.scrape &&
          other.scrapeOnly == this.scrapeOnly &&
          other.stage == this.stage &&
          other.message == this.message &&
          other.importedCount == this.importedCount &&
          other.videoCount == this.videoCount &&
          other.folderCount == this.folderCount &&
          other.subtitleCount == this.subtitleCount &&
          other.progress == this.progress &&
          other.batchId == this.batchId &&
          other.createdAt == this.createdAt &&
          other.scanJson == this.scanJson &&
          other.decisionsJson == this.decisionsJson);
}

class TasksCompanion extends UpdateCompanion<TaskRow> {
  final Value<String> id;
  final Value<String> connectionId;
  final Value<String> pathsJson;
  final Value<String> mode;
  final Value<bool> scrape;
  final Value<bool> scrapeOnly;
  final Value<String> stage;
  final Value<String> message;
  final Value<int> importedCount;
  final Value<int> videoCount;
  final Value<int> folderCount;
  final Value<int> subtitleCount;
  final Value<double?> progress;
  final Value<String?> batchId;
  final Value<DateTime> createdAt;
  final Value<String?> scanJson;
  final Value<String?> decisionsJson;
  final Value<int> rowid;
  const TasksCompanion({
    this.id = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.pathsJson = const Value.absent(),
    this.mode = const Value.absent(),
    this.scrape = const Value.absent(),
    this.scrapeOnly = const Value.absent(),
    this.stage = const Value.absent(),
    this.message = const Value.absent(),
    this.importedCount = const Value.absent(),
    this.videoCount = const Value.absent(),
    this.folderCount = const Value.absent(),
    this.subtitleCount = const Value.absent(),
    this.progress = const Value.absent(),
    this.batchId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.scanJson = const Value.absent(),
    this.decisionsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TasksCompanion.insert({
    required String id,
    required String connectionId,
    required String pathsJson,
    required String mode,
    this.scrape = const Value.absent(),
    this.scrapeOnly = const Value.absent(),
    required String stage,
    required String message,
    required int importedCount,
    required int videoCount,
    required int folderCount,
    required int subtitleCount,
    this.progress = const Value.absent(),
    this.batchId = const Value.absent(),
    required DateTime createdAt,
    this.scanJson = const Value.absent(),
    this.decisionsJson = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       connectionId = Value(connectionId),
       pathsJson = Value(pathsJson),
       mode = Value(mode),
       stage = Value(stage),
       message = Value(message),
       importedCount = Value(importedCount),
       videoCount = Value(videoCount),
       folderCount = Value(folderCount),
       subtitleCount = Value(subtitleCount),
       createdAt = Value(createdAt);
  static Insertable<TaskRow> custom({
    Expression<String>? id,
    Expression<String>? connectionId,
    Expression<String>? pathsJson,
    Expression<String>? mode,
    Expression<bool>? scrape,
    Expression<bool>? scrapeOnly,
    Expression<String>? stage,
    Expression<String>? message,
    Expression<int>? importedCount,
    Expression<int>? videoCount,
    Expression<int>? folderCount,
    Expression<int>? subtitleCount,
    Expression<double>? progress,
    Expression<String>? batchId,
    Expression<DateTime>? createdAt,
    Expression<String>? scanJson,
    Expression<String>? decisionsJson,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (connectionId != null) 'connection_id': connectionId,
      if (pathsJson != null) 'paths_json': pathsJson,
      if (mode != null) 'mode': mode,
      if (scrape != null) 'scrape': scrape,
      if (scrapeOnly != null) 'scrape_only': scrapeOnly,
      if (stage != null) 'stage': stage,
      if (message != null) 'message': message,
      if (importedCount != null) 'imported_count': importedCount,
      if (videoCount != null) 'video_count': videoCount,
      if (folderCount != null) 'folder_count': folderCount,
      if (subtitleCount != null) 'subtitle_count': subtitleCount,
      if (progress != null) 'progress': progress,
      if (batchId != null) 'batch_id': batchId,
      if (createdAt != null) 'created_at': createdAt,
      if (scanJson != null) 'scan_json': scanJson,
      if (decisionsJson != null) 'decisions_json': decisionsJson,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TasksCompanion copyWith({
    Value<String>? id,
    Value<String>? connectionId,
    Value<String>? pathsJson,
    Value<String>? mode,
    Value<bool>? scrape,
    Value<bool>? scrapeOnly,
    Value<String>? stage,
    Value<String>? message,
    Value<int>? importedCount,
    Value<int>? videoCount,
    Value<int>? folderCount,
    Value<int>? subtitleCount,
    Value<double?>? progress,
    Value<String?>? batchId,
    Value<DateTime>? createdAt,
    Value<String?>? scanJson,
    Value<String?>? decisionsJson,
    Value<int>? rowid,
  }) {
    return TasksCompanion(
      id: id ?? this.id,
      connectionId: connectionId ?? this.connectionId,
      pathsJson: pathsJson ?? this.pathsJson,
      mode: mode ?? this.mode,
      scrape: scrape ?? this.scrape,
      scrapeOnly: scrapeOnly ?? this.scrapeOnly,
      stage: stage ?? this.stage,
      message: message ?? this.message,
      importedCount: importedCount ?? this.importedCount,
      videoCount: videoCount ?? this.videoCount,
      folderCount: folderCount ?? this.folderCount,
      subtitleCount: subtitleCount ?? this.subtitleCount,
      progress: progress ?? this.progress,
      batchId: batchId ?? this.batchId,
      createdAt: createdAt ?? this.createdAt,
      scanJson: scanJson ?? this.scanJson,
      decisionsJson: decisionsJson ?? this.decisionsJson,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (pathsJson.present) {
      map['paths_json'] = Variable<String>(pathsJson.value);
    }
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (scrape.present) {
      map['scrape'] = Variable<bool>(scrape.value);
    }
    if (scrapeOnly.present) {
      map['scrape_only'] = Variable<bool>(scrapeOnly.value);
    }
    if (stage.present) {
      map['stage'] = Variable<String>(stage.value);
    }
    if (message.present) {
      map['message'] = Variable<String>(message.value);
    }
    if (importedCount.present) {
      map['imported_count'] = Variable<int>(importedCount.value);
    }
    if (videoCount.present) {
      map['video_count'] = Variable<int>(videoCount.value);
    }
    if (folderCount.present) {
      map['folder_count'] = Variable<int>(folderCount.value);
    }
    if (subtitleCount.present) {
      map['subtitle_count'] = Variable<int>(subtitleCount.value);
    }
    if (progress.present) {
      map['progress'] = Variable<double>(progress.value);
    }
    if (batchId.present) {
      map['batch_id'] = Variable<String>(batchId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (scanJson.present) {
      map['scan_json'] = Variable<String>(scanJson.value);
    }
    if (decisionsJson.present) {
      map['decisions_json'] = Variable<String>(decisionsJson.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TasksCompanion(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('pathsJson: $pathsJson, ')
          ..write('mode: $mode, ')
          ..write('scrape: $scrape, ')
          ..write('scrapeOnly: $scrapeOnly, ')
          ..write('stage: $stage, ')
          ..write('message: $message, ')
          ..write('importedCount: $importedCount, ')
          ..write('videoCount: $videoCount, ')
          ..write('folderCount: $folderCount, ')
          ..write('subtitleCount: $subtitleCount, ')
          ..write('progress: $progress, ')
          ..write('batchId: $batchId, ')
          ..write('createdAt: $createdAt, ')
          ..write('scanJson: $scanJson, ')
          ..write('decisionsJson: $decisionsJson, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FolderStatsCacheTable extends FolderStatsCache
    with TableInfo<$FolderStatsCacheTable, FolderStatsCacheRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FolderStatsCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dirPathMeta = const VerificationMeta(
    'dirPath',
  );
  @override
  late final GeneratedColumn<String> dirPath = GeneratedColumn<String>(
    'dir_path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _entriesJsonMeta = const VerificationMeta(
    'entriesJson',
  );
  @override
  late final GeneratedColumn<String> entriesJson = GeneratedColumn<String>(
    'entries_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _completeMeta = const VerificationMeta(
    'complete',
  );
  @override
  late final GeneratedColumn<bool> complete = GeneratedColumn<bool>(
    'complete',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("complete" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _scannedAtMeta = const VerificationMeta(
    'scannedAt',
  );
  @override
  late final GeneratedColumn<DateTime> scannedAt = GeneratedColumn<DateTime>(
    'scanned_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    connectionId,
    dirPath,
    entriesJson,
    complete,
    scannedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'folder_stats_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<FolderStatsCacheRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('dir_path')) {
      context.handle(
        _dirPathMeta,
        dirPath.isAcceptableOrUnknown(data['dir_path']!, _dirPathMeta),
      );
    } else if (isInserting) {
      context.missing(_dirPathMeta);
    }
    if (data.containsKey('entries_json')) {
      context.handle(
        _entriesJsonMeta,
        entriesJson.isAcceptableOrUnknown(
          data['entries_json']!,
          _entriesJsonMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_entriesJsonMeta);
    }
    if (data.containsKey('complete')) {
      context.handle(
        _completeMeta,
        complete.isAcceptableOrUnknown(data['complete']!, _completeMeta),
      );
    }
    if (data.containsKey('scanned_at')) {
      context.handle(
        _scannedAtMeta,
        scannedAt.isAcceptableOrUnknown(data['scanned_at']!, _scannedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_scannedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {connectionId, dirPath};
  @override
  FolderStatsCacheRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FolderStatsCacheRow(
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      dirPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}dir_path'],
      )!,
      entriesJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}entries_json'],
      )!,
      complete: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}complete'],
      )!,
      scannedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}scanned_at'],
      )!,
    );
  }

  @override
  $FolderStatsCacheTable createAlias(String alias) {
    return $FolderStatsCacheTable(attachedDatabase, alias);
  }
}

class FolderStatsCacheRow extends DataClass
    implements Insertable<FolderStatsCacheRow> {
  final String connectionId;
  final String dirPath;

  /// JSON array of serialized RemoteEntry objects: {p, n, d, s, m}.
  final String entriesJson;
  final bool complete;
  final DateTime scannedAt;
  const FolderStatsCacheRow({
    required this.connectionId,
    required this.dirPath,
    required this.entriesJson,
    required this.complete,
    required this.scannedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['connection_id'] = Variable<String>(connectionId);
    map['dir_path'] = Variable<String>(dirPath);
    map['entries_json'] = Variable<String>(entriesJson);
    map['complete'] = Variable<bool>(complete);
    map['scanned_at'] = Variable<DateTime>(scannedAt);
    return map;
  }

  FolderStatsCacheCompanion toCompanion(bool nullToAbsent) {
    return FolderStatsCacheCompanion(
      connectionId: Value(connectionId),
      dirPath: Value(dirPath),
      entriesJson: Value(entriesJson),
      complete: Value(complete),
      scannedAt: Value(scannedAt),
    );
  }

  factory FolderStatsCacheRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FolderStatsCacheRow(
      connectionId: serializer.fromJson<String>(json['connectionId']),
      dirPath: serializer.fromJson<String>(json['dirPath']),
      entriesJson: serializer.fromJson<String>(json['entriesJson']),
      complete: serializer.fromJson<bool>(json['complete']),
      scannedAt: serializer.fromJson<DateTime>(json['scannedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'connectionId': serializer.toJson<String>(connectionId),
      'dirPath': serializer.toJson<String>(dirPath),
      'entriesJson': serializer.toJson<String>(entriesJson),
      'complete': serializer.toJson<bool>(complete),
      'scannedAt': serializer.toJson<DateTime>(scannedAt),
    };
  }

  FolderStatsCacheRow copyWith({
    String? connectionId,
    String? dirPath,
    String? entriesJson,
    bool? complete,
    DateTime? scannedAt,
  }) => FolderStatsCacheRow(
    connectionId: connectionId ?? this.connectionId,
    dirPath: dirPath ?? this.dirPath,
    entriesJson: entriesJson ?? this.entriesJson,
    complete: complete ?? this.complete,
    scannedAt: scannedAt ?? this.scannedAt,
  );
  FolderStatsCacheRow copyWithCompanion(FolderStatsCacheCompanion data) {
    return FolderStatsCacheRow(
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      dirPath: data.dirPath.present ? data.dirPath.value : this.dirPath,
      entriesJson: data.entriesJson.present
          ? data.entriesJson.value
          : this.entriesJson,
      complete: data.complete.present ? data.complete.value : this.complete,
      scannedAt: data.scannedAt.present ? data.scannedAt.value : this.scannedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FolderStatsCacheRow(')
          ..write('connectionId: $connectionId, ')
          ..write('dirPath: $dirPath, ')
          ..write('entriesJson: $entriesJson, ')
          ..write('complete: $complete, ')
          ..write('scannedAt: $scannedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(connectionId, dirPath, entriesJson, complete, scannedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FolderStatsCacheRow &&
          other.connectionId == this.connectionId &&
          other.dirPath == this.dirPath &&
          other.entriesJson == this.entriesJson &&
          other.complete == this.complete &&
          other.scannedAt == this.scannedAt);
}

class FolderStatsCacheCompanion extends UpdateCompanion<FolderStatsCacheRow> {
  final Value<String> connectionId;
  final Value<String> dirPath;
  final Value<String> entriesJson;
  final Value<bool> complete;
  final Value<DateTime> scannedAt;
  final Value<int> rowid;
  const FolderStatsCacheCompanion({
    this.connectionId = const Value.absent(),
    this.dirPath = const Value.absent(),
    this.entriesJson = const Value.absent(),
    this.complete = const Value.absent(),
    this.scannedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FolderStatsCacheCompanion.insert({
    required String connectionId,
    required String dirPath,
    required String entriesJson,
    this.complete = const Value.absent(),
    required DateTime scannedAt,
    this.rowid = const Value.absent(),
  }) : connectionId = Value(connectionId),
       dirPath = Value(dirPath),
       entriesJson = Value(entriesJson),
       scannedAt = Value(scannedAt);
  static Insertable<FolderStatsCacheRow> custom({
    Expression<String>? connectionId,
    Expression<String>? dirPath,
    Expression<String>? entriesJson,
    Expression<bool>? complete,
    Expression<DateTime>? scannedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (connectionId != null) 'connection_id': connectionId,
      if (dirPath != null) 'dir_path': dirPath,
      if (entriesJson != null) 'entries_json': entriesJson,
      if (complete != null) 'complete': complete,
      if (scannedAt != null) 'scanned_at': scannedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FolderStatsCacheCompanion copyWith({
    Value<String>? connectionId,
    Value<String>? dirPath,
    Value<String>? entriesJson,
    Value<bool>? complete,
    Value<DateTime>? scannedAt,
    Value<int>? rowid,
  }) {
    return FolderStatsCacheCompanion(
      connectionId: connectionId ?? this.connectionId,
      dirPath: dirPath ?? this.dirPath,
      entriesJson: entriesJson ?? this.entriesJson,
      complete: complete ?? this.complete,
      scannedAt: scannedAt ?? this.scannedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (dirPath.present) {
      map['dir_path'] = Variable<String>(dirPath.value);
    }
    if (entriesJson.present) {
      map['entries_json'] = Variable<String>(entriesJson.value);
    }
    if (complete.present) {
      map['complete'] = Variable<bool>(complete.value);
    }
    if (scannedAt.present) {
      map['scanned_at'] = Variable<DateTime>(scannedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FolderStatsCacheCompanion(')
          ..write('connectionId: $connectionId, ')
          ..write('dirPath: $dirPath, ')
          ..write('entriesJson: $entriesJson, ')
          ..write('complete: $complete, ')
          ..write('scannedAt: $scannedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $WatchRulesTable extends WatchRules
    with TableInfo<$WatchRulesTable, WatchRuleRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $WatchRulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _intervalMinutesMeta = const VerificationMeta(
    'intervalMinutes',
  );
  @override
  late final GeneratedColumn<int> intervalMinutes = GeneratedColumn<int>(
    'interval_minutes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(10),
  );
  static const VerificationMeta _modeMeta = const VerificationMeta('mode');
  @override
  late final GeneratedColumn<String> mode = GeneratedColumn<String>(
    'mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('inPlace'),
  );
  static const VerificationMeta _scrapeMeta = const VerificationMeta('scrape');
  @override
  late final GeneratedColumn<bool> scrape = GeneratedColumn<bool>(
    'scrape',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("scrape" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _autoRunHighConfidenceMeta =
      const VerificationMeta('autoRunHighConfidence');
  @override
  late final GeneratedColumn<bool> autoRunHighConfidence =
      GeneratedColumn<bool>(
        'auto_run_high_confidence',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("auto_run_high_confidence" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  static const VerificationMeta _lastScanAtMeta = const VerificationMeta(
    'lastScanAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastScanAt = GeneratedColumn<DateTime>(
    'last_scan_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastStatusMeta = const VerificationMeta(
    'lastStatus',
  );
  @override
  late final GeneratedColumn<String> lastStatus = GeneratedColumn<String>(
    'last_status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    connectionId,
    path,
    enabled,
    intervalMinutes,
    mode,
    scrape,
    autoRunHighConfidence,
    lastScanAt,
    lastStatus,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'watch_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<WatchRuleRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('interval_minutes')) {
      context.handle(
        _intervalMinutesMeta,
        intervalMinutes.isAcceptableOrUnknown(
          data['interval_minutes']!,
          _intervalMinutesMeta,
        ),
      );
    }
    if (data.containsKey('mode')) {
      context.handle(
        _modeMeta,
        mode.isAcceptableOrUnknown(data['mode']!, _modeMeta),
      );
    }
    if (data.containsKey('scrape')) {
      context.handle(
        _scrapeMeta,
        scrape.isAcceptableOrUnknown(data['scrape']!, _scrapeMeta),
      );
    }
    if (data.containsKey('auto_run_high_confidence')) {
      context.handle(
        _autoRunHighConfidenceMeta,
        autoRunHighConfidence.isAcceptableOrUnknown(
          data['auto_run_high_confidence']!,
          _autoRunHighConfidenceMeta,
        ),
      );
    }
    if (data.containsKey('last_scan_at')) {
      context.handle(
        _lastScanAtMeta,
        lastScanAt.isAcceptableOrUnknown(
          data['last_scan_at']!,
          _lastScanAtMeta,
        ),
      );
    }
    if (data.containsKey('last_status')) {
      context.handle(
        _lastStatusMeta,
        lastStatus.isAcceptableOrUnknown(data['last_status']!, _lastStatusMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  WatchRuleRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return WatchRuleRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      intervalMinutes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}interval_minutes'],
      )!,
      mode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mode'],
      )!,
      scrape: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}scrape'],
      )!,
      autoRunHighConfidence: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}auto_run_high_confidence'],
      )!,
      lastScanAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_scan_at'],
      ),
      lastStatus: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_status'],
      )!,
    );
  }

  @override
  $WatchRulesTable createAlias(String alias) {
    return $WatchRulesTable(attachedDatabase, alias);
  }
}

class WatchRuleRow extends DataClass implements Insertable<WatchRuleRow> {
  final String id;
  final String connectionId;
  final String path;
  final bool enabled;
  final int intervalMinutes;
  final String mode;
  final bool scrape;
  final bool autoRunHighConfidence;
  final DateTime? lastScanAt;
  final String lastStatus;
  const WatchRuleRow({
    required this.id,
    required this.connectionId,
    required this.path,
    required this.enabled,
    required this.intervalMinutes,
    required this.mode,
    required this.scrape,
    required this.autoRunHighConfidence,
    this.lastScanAt,
    required this.lastStatus,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['connection_id'] = Variable<String>(connectionId);
    map['path'] = Variable<String>(path);
    map['enabled'] = Variable<bool>(enabled);
    map['interval_minutes'] = Variable<int>(intervalMinutes);
    map['mode'] = Variable<String>(mode);
    map['scrape'] = Variable<bool>(scrape);
    map['auto_run_high_confidence'] = Variable<bool>(autoRunHighConfidence);
    if (!nullToAbsent || lastScanAt != null) {
      map['last_scan_at'] = Variable<DateTime>(lastScanAt);
    }
    map['last_status'] = Variable<String>(lastStatus);
    return map;
  }

  WatchRulesCompanion toCompanion(bool nullToAbsent) {
    return WatchRulesCompanion(
      id: Value(id),
      connectionId: Value(connectionId),
      path: Value(path),
      enabled: Value(enabled),
      intervalMinutes: Value(intervalMinutes),
      mode: Value(mode),
      scrape: Value(scrape),
      autoRunHighConfidence: Value(autoRunHighConfidence),
      lastScanAt: lastScanAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastScanAt),
      lastStatus: Value(lastStatus),
    );
  }

  factory WatchRuleRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return WatchRuleRow(
      id: serializer.fromJson<String>(json['id']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      path: serializer.fromJson<String>(json['path']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      intervalMinutes: serializer.fromJson<int>(json['intervalMinutes']),
      mode: serializer.fromJson<String>(json['mode']),
      scrape: serializer.fromJson<bool>(json['scrape']),
      autoRunHighConfidence: serializer.fromJson<bool>(
        json['autoRunHighConfidence'],
      ),
      lastScanAt: serializer.fromJson<DateTime?>(json['lastScanAt']),
      lastStatus: serializer.fromJson<String>(json['lastStatus']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'connectionId': serializer.toJson<String>(connectionId),
      'path': serializer.toJson<String>(path),
      'enabled': serializer.toJson<bool>(enabled),
      'intervalMinutes': serializer.toJson<int>(intervalMinutes),
      'mode': serializer.toJson<String>(mode),
      'scrape': serializer.toJson<bool>(scrape),
      'autoRunHighConfidence': serializer.toJson<bool>(autoRunHighConfidence),
      'lastScanAt': serializer.toJson<DateTime?>(lastScanAt),
      'lastStatus': serializer.toJson<String>(lastStatus),
    };
  }

  WatchRuleRow copyWith({
    String? id,
    String? connectionId,
    String? path,
    bool? enabled,
    int? intervalMinutes,
    String? mode,
    bool? scrape,
    bool? autoRunHighConfidence,
    Value<DateTime?> lastScanAt = const Value.absent(),
    String? lastStatus,
  }) => WatchRuleRow(
    id: id ?? this.id,
    connectionId: connectionId ?? this.connectionId,
    path: path ?? this.path,
    enabled: enabled ?? this.enabled,
    intervalMinutes: intervalMinutes ?? this.intervalMinutes,
    mode: mode ?? this.mode,
    scrape: scrape ?? this.scrape,
    autoRunHighConfidence: autoRunHighConfidence ?? this.autoRunHighConfidence,
    lastScanAt: lastScanAt.present ? lastScanAt.value : this.lastScanAt,
    lastStatus: lastStatus ?? this.lastStatus,
  );
  WatchRuleRow copyWithCompanion(WatchRulesCompanion data) {
    return WatchRuleRow(
      id: data.id.present ? data.id.value : this.id,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      path: data.path.present ? data.path.value : this.path,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      intervalMinutes: data.intervalMinutes.present
          ? data.intervalMinutes.value
          : this.intervalMinutes,
      mode: data.mode.present ? data.mode.value : this.mode,
      scrape: data.scrape.present ? data.scrape.value : this.scrape,
      autoRunHighConfidence: data.autoRunHighConfidence.present
          ? data.autoRunHighConfidence.value
          : this.autoRunHighConfidence,
      lastScanAt: data.lastScanAt.present
          ? data.lastScanAt.value
          : this.lastScanAt,
      lastStatus: data.lastStatus.present
          ? data.lastStatus.value
          : this.lastStatus,
    );
  }

  @override
  String toString() {
    return (StringBuffer('WatchRuleRow(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('path: $path, ')
          ..write('enabled: $enabled, ')
          ..write('intervalMinutes: $intervalMinutes, ')
          ..write('mode: $mode, ')
          ..write('scrape: $scrape, ')
          ..write('autoRunHighConfidence: $autoRunHighConfidence, ')
          ..write('lastScanAt: $lastScanAt, ')
          ..write('lastStatus: $lastStatus')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    connectionId,
    path,
    enabled,
    intervalMinutes,
    mode,
    scrape,
    autoRunHighConfidence,
    lastScanAt,
    lastStatus,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is WatchRuleRow &&
          other.id == this.id &&
          other.connectionId == this.connectionId &&
          other.path == this.path &&
          other.enabled == this.enabled &&
          other.intervalMinutes == this.intervalMinutes &&
          other.mode == this.mode &&
          other.scrape == this.scrape &&
          other.autoRunHighConfidence == this.autoRunHighConfidence &&
          other.lastScanAt == this.lastScanAt &&
          other.lastStatus == this.lastStatus);
}

class WatchRulesCompanion extends UpdateCompanion<WatchRuleRow> {
  final Value<String> id;
  final Value<String> connectionId;
  final Value<String> path;
  final Value<bool> enabled;
  final Value<int> intervalMinutes;
  final Value<String> mode;
  final Value<bool> scrape;
  final Value<bool> autoRunHighConfidence;
  final Value<DateTime?> lastScanAt;
  final Value<String> lastStatus;
  final Value<int> rowid;
  const WatchRulesCompanion({
    this.id = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.path = const Value.absent(),
    this.enabled = const Value.absent(),
    this.intervalMinutes = const Value.absent(),
    this.mode = const Value.absent(),
    this.scrape = const Value.absent(),
    this.autoRunHighConfidence = const Value.absent(),
    this.lastScanAt = const Value.absent(),
    this.lastStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  WatchRulesCompanion.insert({
    required String id,
    required String connectionId,
    required String path,
    this.enabled = const Value.absent(),
    this.intervalMinutes = const Value.absent(),
    this.mode = const Value.absent(),
    this.scrape = const Value.absent(),
    this.autoRunHighConfidence = const Value.absent(),
    this.lastScanAt = const Value.absent(),
    this.lastStatus = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       connectionId = Value(connectionId),
       path = Value(path);
  static Insertable<WatchRuleRow> custom({
    Expression<String>? id,
    Expression<String>? connectionId,
    Expression<String>? path,
    Expression<bool>? enabled,
    Expression<int>? intervalMinutes,
    Expression<String>? mode,
    Expression<bool>? scrape,
    Expression<bool>? autoRunHighConfidence,
    Expression<DateTime>? lastScanAt,
    Expression<String>? lastStatus,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (connectionId != null) 'connection_id': connectionId,
      if (path != null) 'path': path,
      if (enabled != null) 'enabled': enabled,
      if (intervalMinutes != null) 'interval_minutes': intervalMinutes,
      if (mode != null) 'mode': mode,
      if (scrape != null) 'scrape': scrape,
      if (autoRunHighConfidence != null)
        'auto_run_high_confidence': autoRunHighConfidence,
      if (lastScanAt != null) 'last_scan_at': lastScanAt,
      if (lastStatus != null) 'last_status': lastStatus,
      if (rowid != null) 'rowid': rowid,
    });
  }

  WatchRulesCompanion copyWith({
    Value<String>? id,
    Value<String>? connectionId,
    Value<String>? path,
    Value<bool>? enabled,
    Value<int>? intervalMinutes,
    Value<String>? mode,
    Value<bool>? scrape,
    Value<bool>? autoRunHighConfidence,
    Value<DateTime?>? lastScanAt,
    Value<String>? lastStatus,
    Value<int>? rowid,
  }) {
    return WatchRulesCompanion(
      id: id ?? this.id,
      connectionId: connectionId ?? this.connectionId,
      path: path ?? this.path,
      enabled: enabled ?? this.enabled,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      mode: mode ?? this.mode,
      scrape: scrape ?? this.scrape,
      autoRunHighConfidence:
          autoRunHighConfidence ?? this.autoRunHighConfidence,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      lastStatus: lastStatus ?? this.lastStatus,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (intervalMinutes.present) {
      map['interval_minutes'] = Variable<int>(intervalMinutes.value);
    }
    if (mode.present) {
      map['mode'] = Variable<String>(mode.value);
    }
    if (scrape.present) {
      map['scrape'] = Variable<bool>(scrape.value);
    }
    if (autoRunHighConfidence.present) {
      map['auto_run_high_confidence'] = Variable<bool>(
        autoRunHighConfidence.value,
      );
    }
    if (lastScanAt.present) {
      map['last_scan_at'] = Variable<DateTime>(lastScanAt.value);
    }
    if (lastStatus.present) {
      map['last_status'] = Variable<String>(lastStatus.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('WatchRulesCompanion(')
          ..write('id: $id, ')
          ..write('connectionId: $connectionId, ')
          ..write('path: $path, ')
          ..write('enabled: $enabled, ')
          ..write('intervalMinutes: $intervalMinutes, ')
          ..write('mode: $mode, ')
          ..write('scrape: $scrape, ')
          ..write('autoRunHighConfidence: $autoRunHighConfidence, ')
          ..write('lastScanAt: $lastScanAt, ')
          ..write('lastStatus: $lastStatus, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $BatchesTable batches = $BatchesTable(this);
  late final $HistoryRecordsTable historyRecords = $HistoryRecordsTable(this);
  late final $TasksTable tasks = $TasksTable(this);
  late final $FolderStatsCacheTable folderStatsCache = $FolderStatsCacheTable(
    this,
  );
  late final $WatchRulesTable watchRules = $WatchRulesTable(this);
  late final Index historyRecordsDstStatus = Index(
    'history_records_dst_status',
    'CREATE INDEX history_records_dst_status ON history_records (dst, status)',
  );
  late final Index folderStatsCacheConn = Index(
    'folder_stats_cache_conn',
    'CREATE INDEX folder_stats_cache_conn ON folder_stats_cache (connection_id)',
  );
  late final Index watchRulesConn = Index(
    'watch_rules_conn',
    'CREATE INDEX watch_rules_conn ON watch_rules (connection_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    batches,
    historyRecords,
    tasks,
    folderStatsCache,
    watchRules,
    historyRecordsDstStatus,
    folderStatsCacheConn,
    watchRulesConn,
  ];
}

typedef $$BatchesTableCreateCompanionBuilder = BatchesCompanion Function({
  required String id,
  required String taskId,
  required String connectionId,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$BatchesTableUpdateCompanionBuilder = BatchesCompanion Function({
  Value<String> id,
  Value<String> taskId,
  Value<String> connectionId,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$BatchesTableReferences
    extends BaseReferences<_$AppDatabase, $BatchesTable, BatchRow> {
  $$BatchesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$HistoryRecordsTable, List<HistoryRow>>
  _historyRecordsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.historyRecords,
    aliasName: 'batches__id__history_records__batch_id',
  );

  $$HistoryRecordsTableProcessedTableManager get historyRecordsRefs {
    final manager = $$HistoryRecordsTableTableManager(
      $_db,
      $_db.historyRecords,
    ).filter((f) => f.batchId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_historyRecordsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$BatchesTableFilterComposer
    extends Composer<_$AppDatabase, $BatchesTable> {
  $$BatchesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> historyRecordsRefs(
    Expression<bool> Function($$HistoryRecordsTableFilterComposer f) f,
  ) {
    final $$HistoryRecordsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.historyRecords,
      getReferencedColumn: (t) => t.batchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HistoryRecordsTableFilterComposer(
            $db: $db,
            $table: $db.historyRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BatchesTableOrderingComposer
    extends Composer<_$AppDatabase, $BatchesTable> {
  $$BatchesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get taskId => $composableBuilder(
    column: $table.taskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$BatchesTableAnnotationComposer
    extends Composer<_$AppDatabase, $BatchesTable> {
  $$BatchesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get taskId =>
      $composableBuilder(column: $table.taskId, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> historyRecordsRefs<T extends Object>(
    Expression<T> Function($$HistoryRecordsTableAnnotationComposer a) f,
  ) {
    final $$HistoryRecordsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.historyRecords,
      getReferencedColumn: (t) => t.batchId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$HistoryRecordsTableAnnotationComposer(
            $db: $db,
            $table: $db.historyRecords,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BatchesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BatchesTable,
          BatchRow,
          $$BatchesTableFilterComposer,
          $$BatchesTableOrderingComposer,
          $$BatchesTableAnnotationComposer,
          $$BatchesTableCreateCompanionBuilder,
          $$BatchesTableUpdateCompanionBuilder,
          (BatchRow, $$BatchesTableReferences),
          BatchRow,
          PrefetchHooks Function({bool historyRecordsRefs})
        > {
  $$BatchesTableTableManager(_$AppDatabase db, $BatchesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$BatchesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$BatchesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$BatchesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> taskId = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => BatchesCompanion(
                id: id,
                taskId: taskId,
                connectionId: connectionId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String taskId,
                required String connectionId,
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => BatchesCompanion.insert(
                id: id,
                taskId: taskId,
                connectionId: connectionId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$BatchesTable, BatchRow>(table),
                  $$BatchesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({historyRecordsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (historyRecordsRefs) db.historyRecords,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (historyRecordsRefs)
                    await $_getPrefetchedDataByColumns<
                      BatchRow,
                      $BatchesTable,
                      HistoryRow,
                      $HistoryRecordsTable
                    >(
                      currentTable: table,
                      referencedTable: $$BatchesTableReferences
                          ._historyRecordsRefsTable(db),
                      managerFromTypedResult: (p0) => $$BatchesTableReferences(
                        db,
                        table,
                        p0,
                      ).historyRecordsRefs,
                      currentColumn: 'id',
                      referencedColumn: 'batch_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$BatchesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BatchesTable,
      BatchRow,
      $$BatchesTableFilterComposer,
      $$BatchesTableOrderingComposer,
      $$BatchesTableAnnotationComposer,
      $$BatchesTableCreateCompanionBuilder,
      $$BatchesTableUpdateCompanionBuilder,
      (BatchRow, $$BatchesTableReferences),
      BatchRow,
      PrefetchHooks Function({bool historyRecordsRefs})
    >;
typedef $$HistoryRecordsTableCreateCompanionBuilder =
    HistoryRecordsCompanion Function({
      required String batchId,
      required String opId,
      required int seq,
      required String kind,
      required String phase,
      required String src,
      required String dst,
      Value<String?> groupId,
      required bool selected,
      Value<String?> warning,
      required String status,
      Value<String?> error,
      required DateTime updatedAt,
      Value<int> rowid,
    });
typedef $$HistoryRecordsTableUpdateCompanionBuilder =
    HistoryRecordsCompanion Function({
      Value<String> batchId,
      Value<String> opId,
      Value<int> seq,
      Value<String> kind,
      Value<String> phase,
      Value<String> src,
      Value<String> dst,
      Value<String?> groupId,
      Value<bool> selected,
      Value<String?> warning,
      Value<String> status,
      Value<String?> error,
      Value<DateTime> updatedAt,
      Value<int> rowid,
    });

final class $$HistoryRecordsTableReferences
    extends BaseReferences<_$AppDatabase, $HistoryRecordsTable, HistoryRow> {
  $$HistoryRecordsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $BatchesTable _batchIdTable(_$AppDatabase db) =>
      db.batches.createAlias('history_records__batch_id__batches__id');

  $$BatchesTableProcessedTableManager get batchId {
    final $_column = $_itemColumn<String>('batch_id')!;

    final manager = $$BatchesTableTableManager(
      $_db,
      $_db.batches,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_batchIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$HistoryRecordsTableFilterComposer
    extends Composer<_$AppDatabase, $HistoryRecordsTable> {
  $$HistoryRecordsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get phase => $composableBuilder(
    column: $table.phase,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get src => $composableBuilder(
    column: $table.src,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dst => $composableBuilder(
    column: $table.dst,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get selected => $composableBuilder(
    column: $table.selected,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get warning => $composableBuilder(
    column: $table.warning,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$BatchesTableFilterComposer get batchId {
    final $$BatchesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.batchId,
      referencedTable: $db.batches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BatchesTableFilterComposer(
            $db: $db,
            $table: $db.batches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HistoryRecordsTableOrderingComposer
    extends Composer<_$AppDatabase, $HistoryRecordsTable> {
  $$HistoryRecordsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get opId => $composableBuilder(
    column: $table.opId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seq => $composableBuilder(
    column: $table.seq,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get phase => $composableBuilder(
    column: $table.phase,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get src => $composableBuilder(
    column: $table.src,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dst => $composableBuilder(
    column: $table.dst,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get groupId => $composableBuilder(
    column: $table.groupId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get selected => $composableBuilder(
    column: $table.selected,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get warning => $composableBuilder(
    column: $table.warning,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get error => $composableBuilder(
    column: $table.error,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$BatchesTableOrderingComposer get batchId {
    final $$BatchesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.batchId,
      referencedTable: $db.batches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BatchesTableOrderingComposer(
            $db: $db,
            $table: $db.batches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HistoryRecordsTableAnnotationComposer
    extends Composer<_$AppDatabase, $HistoryRecordsTable> {
  $$HistoryRecordsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get opId =>
      $composableBuilder(column: $table.opId, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get phase =>
      $composableBuilder(column: $table.phase, builder: (column) => column);

  GeneratedColumn<String> get src =>
      $composableBuilder(column: $table.src, builder: (column) => column);

  GeneratedColumn<String> get dst =>
      $composableBuilder(column: $table.dst, builder: (column) => column);

  GeneratedColumn<String> get groupId =>
      $composableBuilder(column: $table.groupId, builder: (column) => column);

  GeneratedColumn<bool> get selected =>
      $composableBuilder(column: $table.selected, builder: (column) => column);

  GeneratedColumn<String> get warning =>
      $composableBuilder(column: $table.warning, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$BatchesTableAnnotationComposer get batchId {
    final $$BatchesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.batchId,
      referencedTable: $db.batches,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$BatchesTableAnnotationComposer(
            $db: $db,
            $table: $db.batches,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$HistoryRecordsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $HistoryRecordsTable,
          HistoryRow,
          $$HistoryRecordsTableFilterComposer,
          $$HistoryRecordsTableOrderingComposer,
          $$HistoryRecordsTableAnnotationComposer,
          $$HistoryRecordsTableCreateCompanionBuilder,
          $$HistoryRecordsTableUpdateCompanionBuilder,
          (HistoryRow, $$HistoryRecordsTableReferences),
          HistoryRow,
          PrefetchHooks Function({bool batchId})
        > {
  $$HistoryRecordsTableTableManager(
    _$AppDatabase db,
    $HistoryRecordsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$HistoryRecordsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$HistoryRecordsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$HistoryRecordsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> batchId = const Value.absent(),
                Value<String> opId = const Value.absent(),
                Value<int> seq = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> phase = const Value.absent(),
                Value<String> src = const Value.absent(),
                Value<String> dst = const Value.absent(),
                Value<String?> groupId = const Value.absent(),
                Value<bool> selected = const Value.absent(),
                Value<String?> warning = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => HistoryRecordsCompanion(
                batchId: batchId,
                opId: opId,
                seq: seq,
                kind: kind,
                phase: phase,
                src: src,
                dst: dst,
                groupId: groupId,
                selected: selected,
                warning: warning,
                status: status,
                error: error,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String batchId,
                required String opId,
                required int seq,
                required String kind,
                required String phase,
                required String src,
                required String dst,
                Value<String?> groupId = const Value.absent(),
                required bool selected,
                Value<String?> warning = const Value.absent(),
                required String status,
                Value<String?> error = const Value.absent(),
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => HistoryRecordsCompanion.insert(
                batchId: batchId,
                opId: opId,
                seq: seq,
                kind: kind,
                phase: phase,
                src: src,
                dst: dst,
                groupId: groupId,
                selected: selected,
                warning: warning,
                status: status,
                error: error,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$HistoryRecordsTable, HistoryRow>(table),
                  $$HistoryRecordsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({batchId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (batchId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.batchId,
                        referencedTable: $$HistoryRecordsTableReferences
                            ._batchIdTable(db),
                        referencedColumn: $$HistoryRecordsTableReferences
                            ._batchIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$HistoryRecordsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $HistoryRecordsTable,
      HistoryRow,
      $$HistoryRecordsTableFilterComposer,
      $$HistoryRecordsTableOrderingComposer,
      $$HistoryRecordsTableAnnotationComposer,
      $$HistoryRecordsTableCreateCompanionBuilder,
      $$HistoryRecordsTableUpdateCompanionBuilder,
      (HistoryRow, $$HistoryRecordsTableReferences),
      HistoryRow,
      PrefetchHooks Function({bool batchId})
    >;
typedef $$TasksTableCreateCompanionBuilder = TasksCompanion Function({
  required String id,
  required String connectionId,
  required String pathsJson,
  required String mode,
  Value<bool> scrape,
  Value<bool> scrapeOnly,
  required String stage,
  required String message,
  required int importedCount,
  required int videoCount,
  required int folderCount,
  required int subtitleCount,
  Value<double?> progress,
  Value<String?> batchId,
  required DateTime createdAt,
  Value<String?> scanJson,
  Value<String?> decisionsJson,
  Value<int> rowid,
});
typedef $$TasksTableUpdateCompanionBuilder = TasksCompanion Function({
  Value<String> id,
  Value<String> connectionId,
  Value<String> pathsJson,
  Value<String> mode,
  Value<bool> scrape,
  Value<bool> scrapeOnly,
  Value<String> stage,
  Value<String> message,
  Value<int> importedCount,
  Value<int> videoCount,
  Value<int> folderCount,
  Value<int> subtitleCount,
  Value<double?> progress,
  Value<String?> batchId,
  Value<DateTime> createdAt,
  Value<String?> scanJson,
  Value<String?> decisionsJson,
  Value<int> rowid,
});

class $$TasksTableFilterComposer extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pathsJson => $composableBuilder(
    column: $table.pathsJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get scrape => $composableBuilder(
    column: $table.scrape,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get scrapeOnly => $composableBuilder(
    column: $table.scrapeOnly,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get stage => $composableBuilder(
    column: $table.stage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get importedCount => $composableBuilder(
    column: $table.importedCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get videoCount => $composableBuilder(
    column: $table.videoCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get folderCount => $composableBuilder(
    column: $table.folderCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get subtitleCount => $composableBuilder(
    column: $table.subtitleCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get batchId => $composableBuilder(
    column: $table.batchId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get scanJson => $composableBuilder(
    column: $table.scanJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get decisionsJson => $composableBuilder(
    column: $table.decisionsJson,
    builder: (column) => ColumnFilters(column),
  );
}

class $$TasksTableOrderingComposer
    extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pathsJson => $composableBuilder(
    column: $table.pathsJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scrape => $composableBuilder(
    column: $table.scrape,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scrapeOnly => $composableBuilder(
    column: $table.scrapeOnly,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get stage => $composableBuilder(
    column: $table.stage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get message => $composableBuilder(
    column: $table.message,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get importedCount => $composableBuilder(
    column: $table.importedCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get videoCount => $composableBuilder(
    column: $table.videoCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get folderCount => $composableBuilder(
    column: $table.folderCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get subtitleCount => $composableBuilder(
    column: $table.subtitleCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get batchId => $composableBuilder(
    column: $table.batchId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get scanJson => $composableBuilder(
    column: $table.scanJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get decisionsJson => $composableBuilder(
    column: $table.decisionsJson,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$TasksTableAnnotationComposer
    extends Composer<_$AppDatabase, $TasksTable> {
  $$TasksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get pathsJson =>
      $composableBuilder(column: $table.pathsJson, builder: (column) => column);

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<bool> get scrape =>
      $composableBuilder(column: $table.scrape, builder: (column) => column);

  GeneratedColumn<bool> get scrapeOnly => $composableBuilder(
    column: $table.scrapeOnly,
    builder: (column) => column,
  );

  GeneratedColumn<String> get stage =>
      $composableBuilder(column: $table.stage, builder: (column) => column);

  GeneratedColumn<String> get message =>
      $composableBuilder(column: $table.message, builder: (column) => column);

  GeneratedColumn<int> get importedCount => $composableBuilder(
    column: $table.importedCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get videoCount => $composableBuilder(
    column: $table.videoCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get folderCount => $composableBuilder(
    column: $table.folderCount,
    builder: (column) => column,
  );

  GeneratedColumn<int> get subtitleCount => $composableBuilder(
    column: $table.subtitleCount,
    builder: (column) => column,
  );

  GeneratedColumn<double> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<String> get batchId =>
      $composableBuilder(column: $table.batchId, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<String> get scanJson =>
      $composableBuilder(column: $table.scanJson, builder: (column) => column);

  GeneratedColumn<String> get decisionsJson => $composableBuilder(
    column: $table.decisionsJson,
    builder: (column) => column,
  );
}

class $$TasksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $TasksTable,
          TaskRow,
          $$TasksTableFilterComposer,
          $$TasksTableOrderingComposer,
          $$TasksTableAnnotationComposer,
          $$TasksTableCreateCompanionBuilder,
          $$TasksTableUpdateCompanionBuilder,
          (TaskRow, BaseReferences<_$AppDatabase, $TasksTable, TaskRow>),
          TaskRow,
          PrefetchHooks Function()
        > {
  $$TasksTableTableManager(_$AppDatabase db, $TasksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TasksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TasksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TasksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> pathsJson = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<bool> scrape = const Value.absent(),
                Value<bool> scrapeOnly = const Value.absent(),
                Value<String> stage = const Value.absent(),
                Value<String> message = const Value.absent(),
                Value<int> importedCount = const Value.absent(),
                Value<int> videoCount = const Value.absent(),
                Value<int> folderCount = const Value.absent(),
                Value<int> subtitleCount = const Value.absent(),
                Value<double?> progress = const Value.absent(),
                Value<String?> batchId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<String?> scanJson = const Value.absent(),
                Value<String?> decisionsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion(
                id: id,
                connectionId: connectionId,
                pathsJson: pathsJson,
                mode: mode,
                scrape: scrape,
                scrapeOnly: scrapeOnly,
                stage: stage,
                message: message,
                importedCount: importedCount,
                videoCount: videoCount,
                folderCount: folderCount,
                subtitleCount: subtitleCount,
                progress: progress,
                batchId: batchId,
                createdAt: createdAt,
                scanJson: scanJson,
                decisionsJson: decisionsJson,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String connectionId,
                required String pathsJson,
                required String mode,
                Value<bool> scrape = const Value.absent(),
                Value<bool> scrapeOnly = const Value.absent(),
                required String stage,
                required String message,
                required int importedCount,
                required int videoCount,
                required int folderCount,
                required int subtitleCount,
                Value<double?> progress = const Value.absent(),
                Value<String?> batchId = const Value.absent(),
                required DateTime createdAt,
                Value<String?> scanJson = const Value.absent(),
                Value<String?> decisionsJson = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => TasksCompanion.insert(
                id: id,
                connectionId: connectionId,
                pathsJson: pathsJson,
                mode: mode,
                scrape: scrape,
                scrapeOnly: scrapeOnly,
                stage: stage,
                message: message,
                importedCount: importedCount,
                videoCount: videoCount,
                folderCount: folderCount,
                subtitleCount: subtitleCount,
                progress: progress,
                batchId: batchId,
                createdAt: createdAt,
                scanJson: scanJson,
                decisionsJson: decisionsJson,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$TasksTable, TaskRow>(table),
                  BaseReferences<_$AppDatabase, $TasksTable, TaskRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$TasksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $TasksTable,
      TaskRow,
      $$TasksTableFilterComposer,
      $$TasksTableOrderingComposer,
      $$TasksTableAnnotationComposer,
      $$TasksTableCreateCompanionBuilder,
      $$TasksTableUpdateCompanionBuilder,
      (TaskRow, BaseReferences<_$AppDatabase, $TasksTable, TaskRow>),
      TaskRow,
      PrefetchHooks Function()
    >;
typedef $$FolderStatsCacheTableCreateCompanionBuilder =
    FolderStatsCacheCompanion Function({
      required String connectionId,
      required String dirPath,
      required String entriesJson,
      Value<bool> complete,
      required DateTime scannedAt,
      Value<int> rowid,
    });
typedef $$FolderStatsCacheTableUpdateCompanionBuilder =
    FolderStatsCacheCompanion Function({
      Value<String> connectionId,
      Value<String> dirPath,
      Value<String> entriesJson,
      Value<bool> complete,
      Value<DateTime> scannedAt,
      Value<int> rowid,
    });

class $$FolderStatsCacheTableFilterComposer
    extends Composer<_$AppDatabase, $FolderStatsCacheTable> {
  $$FolderStatsCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get dirPath => $composableBuilder(
    column: $table.dirPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get entriesJson => $composableBuilder(
    column: $table.entriesJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get complete => $composableBuilder(
    column: $table.complete,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get scannedAt => $composableBuilder(
    column: $table.scannedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$FolderStatsCacheTableOrderingComposer
    extends Composer<_$AppDatabase, $FolderStatsCacheTable> {
  $$FolderStatsCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get dirPath => $composableBuilder(
    column: $table.dirPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get entriesJson => $composableBuilder(
    column: $table.entriesJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get complete => $composableBuilder(
    column: $table.complete,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get scannedAt => $composableBuilder(
    column: $table.scannedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$FolderStatsCacheTableAnnotationComposer
    extends Composer<_$AppDatabase, $FolderStatsCacheTable> {
  $$FolderStatsCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get dirPath =>
      $composableBuilder(column: $table.dirPath, builder: (column) => column);

  GeneratedColumn<String> get entriesJson => $composableBuilder(
    column: $table.entriesJson,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get complete =>
      $composableBuilder(column: $table.complete, builder: (column) => column);

  GeneratedColumn<DateTime> get scannedAt =>
      $composableBuilder(column: $table.scannedAt, builder: (column) => column);
}

class $$FolderStatsCacheTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $FolderStatsCacheTable,
          FolderStatsCacheRow,
          $$FolderStatsCacheTableFilterComposer,
          $$FolderStatsCacheTableOrderingComposer,
          $$FolderStatsCacheTableAnnotationComposer,
          $$FolderStatsCacheTableCreateCompanionBuilder,
          $$FolderStatsCacheTableUpdateCompanionBuilder,
          (
            FolderStatsCacheRow,
            BaseReferences<
              _$AppDatabase,
              $FolderStatsCacheTable,
              FolderStatsCacheRow
            >,
          ),
          FolderStatsCacheRow,
          PrefetchHooks Function()
        > {
  $$FolderStatsCacheTableTableManager(
    _$AppDatabase db,
    $FolderStatsCacheTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FolderStatsCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FolderStatsCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FolderStatsCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> connectionId = const Value.absent(),
                Value<String> dirPath = const Value.absent(),
                Value<String> entriesJson = const Value.absent(),
                Value<bool> complete = const Value.absent(),
                Value<DateTime> scannedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => FolderStatsCacheCompanion(
                connectionId: connectionId,
                dirPath: dirPath,
                entriesJson: entriesJson,
                complete: complete,
                scannedAt: scannedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String connectionId,
                required String dirPath,
                required String entriesJson,
                Value<bool> complete = const Value.absent(),
                required DateTime scannedAt,
                Value<int> rowid = const Value.absent(),
              }) => FolderStatsCacheCompanion.insert(
                connectionId: connectionId,
                dirPath: dirPath,
                entriesJson: entriesJson,
                complete: complete,
                scannedAt: scannedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$FolderStatsCacheTable, FolderStatsCacheRow>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $FolderStatsCacheTable,
                    FolderStatsCacheRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$FolderStatsCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $FolderStatsCacheTable,
      FolderStatsCacheRow,
      $$FolderStatsCacheTableFilterComposer,
      $$FolderStatsCacheTableOrderingComposer,
      $$FolderStatsCacheTableAnnotationComposer,
      $$FolderStatsCacheTableCreateCompanionBuilder,
      $$FolderStatsCacheTableUpdateCompanionBuilder,
      (
        FolderStatsCacheRow,
        BaseReferences<
          _$AppDatabase,
          $FolderStatsCacheTable,
          FolderStatsCacheRow
        >,
      ),
      FolderStatsCacheRow,
      PrefetchHooks Function()
    >;
typedef $$WatchRulesTableCreateCompanionBuilder = WatchRulesCompanion Function({
  required String id,
  required String connectionId,
  required String path,
  Value<bool> enabled,
  Value<int> intervalMinutes,
  Value<String> mode,
  Value<bool> scrape,
  Value<bool> autoRunHighConfidence,
  Value<DateTime?> lastScanAt,
  Value<String> lastStatus,
  Value<int> rowid,
});
typedef $$WatchRulesTableUpdateCompanionBuilder = WatchRulesCompanion Function({
  Value<String> id,
  Value<String> connectionId,
  Value<String> path,
  Value<bool> enabled,
  Value<int> intervalMinutes,
  Value<String> mode,
  Value<bool> scrape,
  Value<bool> autoRunHighConfidence,
  Value<DateTime?> lastScanAt,
  Value<String> lastStatus,
  Value<int> rowid,
});

class $$WatchRulesTableFilterComposer
    extends Composer<_$AppDatabase, $WatchRulesTable> {
  $$WatchRulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get intervalMinutes => $composableBuilder(
    column: $table.intervalMinutes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get scrape => $composableBuilder(
    column: $table.scrape,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get autoRunHighConfidence => $composableBuilder(
    column: $table.autoRunHighConfidence,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastScanAt => $composableBuilder(
    column: $table.lastScanAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => ColumnFilters(column),
  );
}

class $$WatchRulesTableOrderingComposer
    extends Composer<_$AppDatabase, $WatchRulesTable> {
  $$WatchRulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get intervalMinutes => $composableBuilder(
    column: $table.intervalMinutes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mode => $composableBuilder(
    column: $table.mode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get scrape => $composableBuilder(
    column: $table.scrape,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get autoRunHighConfidence => $composableBuilder(
    column: $table.autoRunHighConfidence,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastScanAt => $composableBuilder(
    column: $table.lastScanAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$WatchRulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $WatchRulesTable> {
  $$WatchRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get connectionId => $composableBuilder(
    column: $table.connectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<int> get intervalMinutes => $composableBuilder(
    column: $table.intervalMinutes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mode =>
      $composableBuilder(column: $table.mode, builder: (column) => column);

  GeneratedColumn<bool> get scrape =>
      $composableBuilder(column: $table.scrape, builder: (column) => column);

  GeneratedColumn<bool> get autoRunHighConfidence => $composableBuilder(
    column: $table.autoRunHighConfidence,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastScanAt => $composableBuilder(
    column: $table.lastScanAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastStatus => $composableBuilder(
    column: $table.lastStatus,
    builder: (column) => column,
  );
}

class $$WatchRulesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $WatchRulesTable,
          WatchRuleRow,
          $$WatchRulesTableFilterComposer,
          $$WatchRulesTableOrderingComposer,
          $$WatchRulesTableAnnotationComposer,
          $$WatchRulesTableCreateCompanionBuilder,
          $$WatchRulesTableUpdateCompanionBuilder,
          (
            WatchRuleRow,
            BaseReferences<_$AppDatabase, $WatchRulesTable, WatchRuleRow>,
          ),
          WatchRuleRow,
          PrefetchHooks Function()
        > {
  $$WatchRulesTableTableManager(_$AppDatabase db, $WatchRulesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$WatchRulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$WatchRulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$WatchRulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<int> intervalMinutes = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<bool> scrape = const Value.absent(),
                Value<bool> autoRunHighConfidence = const Value.absent(),
                Value<DateTime?> lastScanAt = const Value.absent(),
                Value<String> lastStatus = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WatchRulesCompanion(
                id: id,
                connectionId: connectionId,
                path: path,
                enabled: enabled,
                intervalMinutes: intervalMinutes,
                mode: mode,
                scrape: scrape,
                autoRunHighConfidence: autoRunHighConfidence,
                lastScanAt: lastScanAt,
                lastStatus: lastStatus,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String connectionId,
                required String path,
                Value<bool> enabled = const Value.absent(),
                Value<int> intervalMinutes = const Value.absent(),
                Value<String> mode = const Value.absent(),
                Value<bool> scrape = const Value.absent(),
                Value<bool> autoRunHighConfidence = const Value.absent(),
                Value<DateTime?> lastScanAt = const Value.absent(),
                Value<String> lastStatus = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => WatchRulesCompanion.insert(
                id: id,
                connectionId: connectionId,
                path: path,
                enabled: enabled,
                intervalMinutes: intervalMinutes,
                mode: mode,
                scrape: scrape,
                autoRunHighConfidence: autoRunHighConfidence,
                lastScanAt: lastScanAt,
                lastStatus: lastStatus,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$WatchRulesTable, WatchRuleRow>(table),
                  BaseReferences<_$AppDatabase, $WatchRulesTable, WatchRuleRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$WatchRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $WatchRulesTable,
      WatchRuleRow,
      $$WatchRulesTableFilterComposer,
      $$WatchRulesTableOrderingComposer,
      $$WatchRulesTableAnnotationComposer,
      $$WatchRulesTableCreateCompanionBuilder,
      $$WatchRulesTableUpdateCompanionBuilder,
      (
        WatchRuleRow,
        BaseReferences<_$AppDatabase, $WatchRulesTable, WatchRuleRow>,
      ),
      WatchRuleRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$BatchesTableTableManager get batches =>
      $$BatchesTableTableManager(_db, _db.batches);
  $$HistoryRecordsTableTableManager get historyRecords =>
      $$HistoryRecordsTableTableManager(_db, _db.historyRecords);
  $$TasksTableTableManager get tasks =>
      $$TasksTableTableManager(_db, _db.tasks);
  $$FolderStatsCacheTableTableManager get folderStatsCache =>
      $$FolderStatsCacheTableTableManager(_db, _db.folderStatsCache);
  $$WatchRulesTableTableManager get watchRules =>
      $$WatchRulesTableTableManager(_db, _db.watchRules);
}
