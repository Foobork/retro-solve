import 'dart:async';
import 'dart:developer';
import 'package:sqflite_common/sqlite_api.dart';
import '../graph/position_eval.dart';
import 'db_init.dart';

class _NodeUpdate {
  final String bfen;
  final PositionEval? assigned;
  final PositionEval? computed;
  _NodeUpdate(this.bfen, this.assigned, this.computed);
}

class _EdgeUpdate {
  final String source;
  final String target;
  _EdgeUpdate(this.source, this.target);
}

class DatabaseService {
  static DatabaseService? _instance;
  Database? _db;

  final Map<String, _NodeUpdate> _updateQueue = {};
  final List<_EdgeUpdate> _edgeQueue = [];
  bool _isFlushing = false;

  DatabaseService._();

  int getEdgeQueueLength() => _edgeQueue.length;
  int getUpdateQueueLength() => _updateQueue.length;

  static DatabaseService get instance {
    _instance ??= DatabaseService._();
    return _instance!;
  }

  Future<void> init(String dbPath) async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
    final factory = getPlatformDatabaseFactory();
    _db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE nodes (
              bfen TEXT PRIMARY KEY,
              assigned_result INTEGER,
              assigned_dtw INTEGER,
              assigned_dtz INTEGER,
              assigned_cp INTEGER,
              computed_result INTEGER,
              computed_dtw INTEGER,
              computed_dtz INTEGER,
              computed_cp INTEGER
            )
          ''');
          await db.execute('''
            CREATE TABLE edges (
              source TEXT,
              target TEXT,
              PRIMARY KEY (source, target)
            )
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await db.execute('''
              CREATE TABLE IF NOT EXISTS edges (
                source TEXT,
                target TEXT,
                PRIMARY KEY (source, target)
              )
            ''');
          }
          if (oldVersion < 3) {
            await _migrateToVersion3(db);
          }
        },
      ),
    );

    // Failsafe migration check: ensure legacy REAL columns are migrated even if version was dirty
    try {
      final tableInfo = await _db!.rawQuery("PRAGMA table_info('nodes');");
      final columnNames =
          tableInfo.map((row) => (row['name'] as String?)?.toLowerCase()).toSet();
      if (columnNames.contains('assigned') || columnNames.contains('computed')) {
        await _migrateToVersion3(_db!);
      }
    } catch (_) {}

    // Failsafe: Ensure tables always exist
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS nodes (
        bfen TEXT PRIMARY KEY,
        assigned_result INTEGER,
        assigned_dtw INTEGER,
        assigned_dtz INTEGER,
        assigned_cp INTEGER,
        computed_result INTEGER,
        computed_dtw INTEGER,
        computed_dtz INTEGER,
        computed_cp INTEGER
      )
    ''');
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS edges (
        source TEXT,
        target TEXT,
        PRIMARY KEY (source, target)
      )
    ''');

    // Enable WAL mode and busy timeout for safe multi-process concurrency
    try {
      await _db!.execute('PRAGMA journal_mode = WAL;');
      await _db!.execute('PRAGMA busy_timeout = 10000;');
    } catch (e) {
      log("Warning setting WAL / busy_timeout: $e");
    }
  }

  static Future<void> _migrateToVersion3(DatabaseExecutor db) async {
    // 1. Create temporary v3 table with pure integer evaluation columns
    await db.execute('''
      CREATE TABLE IF NOT EXISTS nodes_v3 (
        bfen TEXT PRIMARY KEY,
        assigned_result INTEGER,
        assigned_dtw INTEGER,
        assigned_dtz INTEGER,
        assigned_cp INTEGER,
        computed_result INTEGER,
        computed_dtw INTEGER,
        computed_dtz INTEGER,
        computed_cp INTEGER
      );
    ''');

    // 2. Read legacy rows
    try {
      final legacyRows = await db.rawQuery('SELECT * FROM nodes;');
      if (legacyRows.isNotEmpty) {
        final batch = db.batch();
        for (var row in legacyRows) {
          final bfen = row['bfen'] as String;
          final legacyAssigned = (row['assigned'] as num?)?.toDouble();
          final legacyComputed = (row['computed'] as num?)?.toDouble();
          final assignedEval = PositionEval.fromLegacyScore(legacyAssigned);
          final computedEval = PositionEval.fromLegacyScore(legacyComputed);

          batch.insert(
            'nodes_v3',
            {
              'bfen': bfen,
              'assigned_result': assignedEval?.result?.value,
              'assigned_dtw': assignedEval?.dtw,
              'assigned_dtz': assignedEval?.dtz,
              'assigned_cp': assignedEval?.cp,
              'computed_result': computedEval?.result?.value,
              'computed_dtw': computedEval?.dtw,
              'computed_dtz': computedEval?.dtz,
              'computed_cp': computedEval?.cp,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }

      // 3. Drop legacy table and rename nodes_v3 -> nodes
      await db.execute('DROP TABLE nodes;');
      await db.execute('ALTER TABLE nodes_v3 RENAME TO nodes;');
    } catch (e) {
      log('Warning migrating nodes to version 3: $e');
    }
  }

  Future<void> upsertNode(String bfen, dynamic assigned, dynamic computed) async {
    if (_db == null) return;
    final assignedEval = assigned is PositionEval?
        ? assigned
        : PositionEval.fromLegacyScore(assigned as double?);
    final computedEval = computed is PositionEval?
        ? computed
        : PositionEval.fromLegacyScore(computed as double?);
    _updateQueue[bfen] = _NodeUpdate(bfen, assignedEval, computedEval);
    _scheduleFlush();
  }

  Future<void> upsertEdge(String source, String target) async {
    if (_db == null) return;
    _edgeQueue.add(_EdgeUpdate(source, target));
    _scheduleFlush();
  }

  void _scheduleFlush() {
    if (_isFlushing || (_updateQueue.isEmpty && _edgeQueue.isEmpty)) return;
    _isFlushing = true;
    Future.delayed(const Duration(milliseconds: 100), _flushQueue);
  }

  Future<void> _flushQueue() async {
    if ((_updateQueue.isEmpty && _edgeQueue.isEmpty) || _db == null) {
      _isFlushing = false;
      return;
    }

    final batchUpdates = _updateQueue.values.toList();
    _updateQueue.clear();
    
    final batchEdges = List<_EdgeUpdate>.from(_edgeQueue);
    _edgeQueue.clear();

    try {
      if (batchUpdates.isNotEmpty) {
        final batch = _db!.batch();
        for (var update in batchUpdates) {
          batch.insert(
            'nodes',
            {
              'bfen': update.bfen,
              'assigned_result': update.assigned?.result?.value,
              'assigned_dtw': update.assigned?.dtw,
              'assigned_dtz': update.assigned?.dtz,
              'assigned_cp': update.assigned?.cp,
              'computed_result': update.computed?.result?.value,
              'computed_dtw': update.computed?.dtw,
              'computed_dtz': update.computed?.dtz,
              'computed_cp': update.computed?.cp,
            },
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
        await batch.commit(noResult: true);
      }

      for (int i = 0; i < batchEdges.length; i += 2000) {
        final chunk = batchEdges.skip(i).take(2000);
        final batch = _db!.batch();
        for (var edge in chunk) {
          batch.insert(
            'edges',
            {
              'source': edge.source,
              'target': edge.target,
            },
            conflictAlgorithm: ConflictAlgorithm.ignore,
          );
        }
        await batch.commit(noResult: true);
      }
    } catch (e) {
      log("Database sync error: $e");
    } finally {
      _isFlushing = false;
      if (_updateQueue.isNotEmpty || _edgeQueue.isNotEmpty) {
        _scheduleFlush();
      }
    }
  }

  Future<List<Map<String, dynamic>>> loadNodes() async {
    if (_db == null) return [];
    return await _db!.query('nodes');
  }

  Future<List<Map<String, dynamic>>> loadEdges() async {
    if (_db == null) return [];
    return await _db!.query('edges');
  }

  Future<void> clearDatabase() async {
    if (_db == null) return;
    await _db!.delete('nodes');
    await _db!.delete('edges');
  }

  Future<void> flush() async {
    while (_isFlushing || _updateQueue.isNotEmpty || _edgeQueue.isNotEmpty) {
      if (!_isFlushing && (_updateQueue.isNotEmpty || _edgeQueue.isNotEmpty)) {
        await _flushQueue();
      } else {
        await Future.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  Future<void> close() async {
    await flush();
    await _db?.close();
    _db = null;
  }
}
