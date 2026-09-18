import 'dart:async';
import 'dart:developer';
import 'package:sqflite_common/sqlite_api.dart';
import '../graph/csr_graph_solver.dart';
import '../graph/lru_map.dart';
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

  // Bounded in-memory LRU cache for fast bidirectional ID <-> BFEN lookups
  final Map<String, int> _bfenToId = LruMap<String, int>(capacity: 100000);
  final Map<int, String> _idToBfen = LruMap<int, String>(capacity: 100000);

  bool get isOpen => _db != null;

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
    _bfenToId.clear();
    _idToBfen.clear();

    final factory = getPlatformDatabaseFactory();
    _db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE positions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              bfen TEXT UNIQUE NOT NULL,
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
          await db.execute('''
            CREATE TABLE edges (
              source_id INTEGER NOT NULL,
              target_id INTEGER NOT NULL,
              PRIMARY KEY (source_id, target_id)
            ) WITHOUT ROWID;
          ''');
          await db.execute('''
            CREATE INDEX idx_edges_target ON edges (target_id, source_id);
          ''');
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 3) {
            await _migrateToVersion3(db);
          }
          if (oldVersion < 4) {
            await _migrateToVersion4(db);
          }
        },
      ),
    );

    // Failsafe migration check: ensure legacy tables/columns are migrated even if version PRAGMA was dirty
    try {
      final tables = (await _db!.rawQuery("SELECT name FROM sqlite_master WHERE type='table';"))
          .map((row) => (row['name'] as String?)?.toLowerCase())
          .toSet();
      if (tables.contains('nodes')) {
        await _migrateToVersion4(_db!);
      } else if (tables.contains('edges')) {
        final edgeInfo = await _db!.rawQuery("PRAGMA table_info('edges');");
        final colNames = edgeInfo.map((r) => (r['name'] as String?)?.toLowerCase()).toSet();
        if (colNames.contains('source') || colNames.contains('target')) {
          await _migrateToVersion4(_db!);
        }
      }
    } catch (e) {
      log("Warning checking schema version: $e");
    }

    // Failsafe: Ensure v4 tables and reverse index always exist
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS positions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bfen TEXT UNIQUE NOT NULL,
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
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS edges (
        source_id INTEGER NOT NULL,
        target_id INTEGER NOT NULL,
        PRIMARY KEY (source_id, target_id)
      ) WITHOUT ROWID;
    ''');
    await _db!.execute('''
      CREATE INDEX IF NOT EXISTS idx_edges_target ON edges (target_id, source_id);
    ''');

    // Enable WAL mode and busy timeout for safe multi-process / multi-isolate concurrency
    try {
      await _db!.execute('PRAGMA journal_mode = WAL;');
      await _db!.execute('PRAGMA busy_timeout = 10000;');
    } catch (e) {
      log("Warning setting WAL / busy_timeout: $e");
    }
  }

  static Future<void> _migrateToVersion3(DatabaseExecutor db) async {
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

      await db.execute('DROP TABLE nodes;');
      await db.execute('ALTER TABLE nodes_v3 RENAME TO nodes;');
    } catch (e) {
      log('Warning migrating nodes to version 3: $e');
    }
  }

  static Future<void> _migrateToVersion4(DatabaseExecutor db) async {
    final tables = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table';"))
        .map((r) => (r['name'] as String).toLowerCase())
        .toSet();

    // If nodes table has legacy REAL columns, migrate to v3 integer format first
    if (tables.contains('nodes')) {
      final tableInfo = await db.rawQuery("PRAGMA table_info('nodes');");
      final colNames = tableInfo.map((r) => (r['name'] as String).toLowerCase()).toSet();
      if (colNames.contains('assigned') || colNames.contains('computed')) {
        await _migrateToVersion3(db);
      }
    }

    // 1. Create positions table
    await db.execute('''
      CREATE TABLE IF NOT EXISTS positions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bfen TEXT UNIQUE NOT NULL,
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

    // 2. Populate positions from nodes if nodes table exists
    if (tables.contains('nodes')) {
      await db.execute('''
        INSERT OR IGNORE INTO positions (
          bfen, assigned_result, assigned_dtw, assigned_dtz, assigned_cp,
          computed_result, computed_dtw, computed_dtz, computed_cp
        ) SELECT
          bfen, assigned_result, assigned_dtw, assigned_dtz, assigned_cp,
          computed_result, computed_dtw, computed_dtz, computed_cp
        FROM nodes;
      ''');
    }

    // 3. Migrate edges if legacy edges table exists
    if (tables.contains('edges')) {
      final edgeInfo = await db.rawQuery("PRAGMA table_info('edges');");
      final colNames = edgeInfo.map((r) => (r['name'] as String).toLowerCase()).toSet();
      if (colNames.contains('source') || colNames.contains('target')) {
        // Ensure all frontier source/targets from edges are recorded in positions
        await db.execute('INSERT OR IGNORE INTO positions (bfen) SELECT DISTINCT source FROM edges;');
        await db.execute('INSERT OR IGNORE INTO positions (bfen) SELECT DISTINCT target FROM edges;');

        // Create new edges_v4 table
        await db.execute('''
          CREATE TABLE IF NOT EXISTS edges_v4 (
            source_id INTEGER NOT NULL,
            target_id INTEGER NOT NULL,
            PRIMARY KEY (source_id, target_id)
          ) WITHOUT ROWID;
        ''');

        // Populate edges_v4 by joining positions on BFEN
        await db.execute('''
          INSERT OR IGNORE INTO edges_v4 (source_id, target_id)
          SELECT ps.id, pt.id
          FROM edges e
          JOIN positions ps ON e.source = ps.bfen
          JOIN positions pt ON e.target = pt.bfen;
        ''');

        // Drop old edges and rename edges_v4 to edges
        await db.execute('DROP TABLE edges;');
        await db.execute('ALTER TABLE edges_v4 RENAME TO edges;');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_edges_target ON edges (target_id, source_id);');
      }
    } else {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS edges (
          source_id INTEGER NOT NULL,
          target_id INTEGER NOT NULL,
          PRIMARY KEY (source_id, target_id)
        ) WITHOUT ROWID;
      ''');
      await db.execute('CREATE INDEX IF NOT EXISTS idx_edges_target ON edges (target_id, source_id);');
    }

    // 4. Drop nodes table if it still exists
    if (tables.contains('nodes')) {
      await db.execute('DROP TABLE nodes;');
    }

    // Update PRAGMA user_version to 4
    try {
      await db.execute('PRAGMA user_version = 4;');
    } catch (_) {}
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
      // 1. Process node updates using UPSERT to preserve integer primary key IDs
      if (batchUpdates.isNotEmpty) {
        final batch = _db!.batch();
        for (var update in batchUpdates) {
          batch.rawInsert('''
            INSERT INTO positions (
              bfen, assigned_result, assigned_dtw, assigned_dtz, assigned_cp,
              computed_result, computed_dtw, computed_dtz, computed_cp
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(bfen) DO UPDATE SET
              assigned_result = excluded.assigned_result,
              assigned_dtw = excluded.assigned_dtw,
              assigned_dtz = excluded.assigned_dtz,
              assigned_cp = excluded.assigned_cp,
              computed_result = excluded.computed_result,
              computed_dtw = excluded.computed_dtw,
              computed_dtz = excluded.computed_dtz,
              computed_cp = excluded.computed_cp;
          ''', [
            update.bfen,
            update.assigned?.result?.value,
            update.assigned?.dtw,
            update.assigned?.dtz,
            update.assigned?.cp,
            update.computed?.result?.value,
            update.computed?.dtw,
            update.computed?.dtz,
            update.computed?.cp,
          ]);
        }
        await batch.commit(noResult: true);
      }

      // 2. Process edge updates
      if (batchEdges.isNotEmpty) {
        // Collect missing BFENs that lack cached integer IDs
        final missingBfens = <String>{};
        for (var edge in batchEdges) {
          if (!_bfenToId.containsKey(edge.source)) missingBfens.add(edge.source);
          if (!_bfenToId.containsKey(edge.target)) missingBfens.add(edge.target);
        }

        if (missingBfens.isNotEmpty) {
          final missingList = missingBfens.toList();
          // Ensure all missing positions are inserted into positions
          for (int i = 0; i < missingList.length; i += 1000) {
            final chunk = missingList.skip(i).take(1000).toList();
            final batch = _db!.batch();
            for (final bfen in chunk) {
              batch.rawInsert(
                'INSERT OR IGNORE INTO positions (bfen) VALUES (?);',
                [bfen],
              );
            }
            await batch.commit(noResult: true);
          }

          // Fetch back newly created/existing IDs to cache them
          for (int i = 0; i < missingList.length; i += 900) {
            final chunk = missingList.skip(i).take(900).toList();
            final placeholders = List.filled(chunk.length, '?').join(',');
            final rows = await _db!.rawQuery(
              'SELECT id, bfen FROM positions WHERE bfen IN ($placeholders);',
              chunk,
            );
            for (final row in rows) {
              final id = row['id'] as int;
              final bfen = row['bfen'] as String;
              _bfenToId[bfen] = id;
              _idToBfen[id] = bfen;
            }
          }
        }

        // Insert compact integer edge pairs
        for (int i = 0; i < batchEdges.length; i += 2000) {
          final chunk = batchEdges.skip(i).take(2000);
          final batch = _db!.batch();
          for (var edge in chunk) {
            final sId = _bfenToId[edge.source];
            final tId = _bfenToId[edge.target];
            if (sId != null && tId != null) {
              batch.rawInsert(
                'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);',
                [sId, tId],
              );
            }
          }
          await batch.commit(noResult: true);
        }
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

  /// Fetches a single position row by its BFEN.
  Future<Map<String, dynamic>?> getNode(String bfen) async {
    if (_db == null) return null;
    final pending = _updateQueue[bfen];
    if (pending != null) {
      return {
        'bfen': bfen,
        'assigned_result': pending.assigned?.result?.value,
        'assigned_dtw': pending.assigned?.dtw,
        'assigned_dtz': pending.assigned?.dtz,
        'assigned_cp': pending.assigned?.cp,
        'computed_result': pending.computed?.result?.value,
        'computed_dtw': pending.computed?.dtw,
        'computed_dtz': pending.computed?.dtz,
        'computed_cp': pending.computed?.cp,
      };
    }
    final rows = await _db!.rawQuery(
      'SELECT * FROM positions WHERE bfen = ? LIMIT 1;',
      [bfen],
    );
    if (rows.isEmpty) return null;
    return rows.first;
  }

  /// Batch-fetches multiple positions by BFEN, checking pending writes first.
  Future<Map<String, Map<String, dynamic>>> getNodes(Iterable<String> bfens) async {
    if (_db == null || bfens.isEmpty) return {};
    final result = <String, Map<String, dynamic>>{};
    final missing = <String>[];

    for (final bfen in bfens) {
      final pending = _updateQueue[bfen];
      if (pending != null) {
        result[bfen] = {
          'bfen': bfen,
          'assigned_result': pending.assigned?.result?.value,
          'assigned_dtw': pending.assigned?.dtw,
          'assigned_dtz': pending.assigned?.dtz,
          'assigned_cp': pending.assigned?.cp,
          'computed_result': pending.computed?.result?.value,
          'computed_dtw': pending.computed?.dtw,
          'computed_dtz': pending.computed?.dtz,
          'computed_cp': pending.computed?.cp,
        };
      } else {
        missing.add(bfen);
      }
    }

    if (missing.isNotEmpty) {
      for (int i = 0; i < missing.length; i += 500) {
        final chunk = missing.skip(i).take(500).toList();
        final placeholders = List.filled(chunk.length, '?').join(',');
        final rows = await _db!.rawQuery(
          'SELECT * FROM positions WHERE bfen IN ($placeholders);',
          chunk,
        );
        for (final row in rows) {
          result[row['bfen'] as String] = row;
        }
      }
    }

    return result;
  }

  /// Returns outgoing edge target BFENs for the given source position.
  Future<List<String>> getChildrenBfens(String bfen) async {
    if (_db == null) return [];
    if (_edgeQueue.isNotEmpty) {
      await flush();
    }
    final rows = await _db!.rawQuery('''
      SELECT pt.bfen
      FROM edges e
      JOIN positions ps ON e.source_id = ps.id
      JOIN positions pt ON e.target_id = pt.id
      WHERE ps.bfen = ?;
    ''', [bfen]);
    return rows.map((r) => r['bfen'] as String).toList();
  }

  /// Returns incoming edge source BFENs (ancestors) for the given target position using idx_edges_target.
  Future<List<String>> getParentBfens(String bfen) async {
    if (_db == null) return [];
    if (_edgeQueue.isNotEmpty) {
      await flush();
    }
    final rows = await _db!.rawQuery('''
      SELECT ps.bfen
      FROM edges e
      JOIN positions pt ON e.target_id = pt.id
      JOIN positions ps ON e.source_id = ps.id
      WHERE pt.bfen = ?;
    ''', [bfen]);
    return rows.map((r) => r['bfen'] as String).toList();
  }

  /// Parses a PositionEval object from a raw positions table row.
  static PositionEval? evalFromRow(Map<String, dynamic> row, String prefix) {
    final resVal = row['${prefix}_result'] as int?;
    final dtw = row['${prefix}_dtw'] as int?;
    final dtz = row['${prefix}_dtz'] as int?;
    final cp = row['${prefix}_cp'] as int?;
    if (resVal == null && dtw == null && dtz == null && cp == null) {
      if (row.containsKey(prefix)) {
        return PositionEval.fromLegacyScore(row[prefix] as double?);
      }
      return null;
    }
    return PositionEval(
      result: GameResult.fromInt(resVal),
      dtw: dtw,
      dtz: dtz,
      cp: cp,
    );
  }

  Future<int> getPositionCount() async {
    if (_db == null) return 0;
    final res = await _db!.rawQuery('SELECT COUNT(1) as cnt FROM positions;');
    return (res.first['cnt'] as num).toInt();
  }

  Future<int> getEdgeCount() async {
    if (_db == null) return 0;
    final res = await _db!.rawQuery('SELECT COUNT(1) as cnt FROM edges;');
    return (res.first['cnt'] as num).toInt();
  }

  /// Paginates through evaluated positions for disk export without memory spikes.
  Future<List<Map<String, dynamic>>> getPositionsForExport({
    int? afterId,
    int limit = 50000,
  }) async {
    if (_db == null) return [];
    if (afterId == null) {
      return await _db!.rawQuery('''
        SELECT id, bfen, assigned_result, assigned_dtw, assigned_dtz, assigned_cp,
               computed_result, computed_dtw, computed_dtz, computed_cp
        FROM positions
        WHERE computed_result IS NOT NULL OR computed_cp IS NOT NULL
        ORDER BY id
        LIMIT ?;
      ''', [limit]);
    } else {
      return await _db!.rawQuery('''
        SELECT id, bfen, assigned_result, assigned_dtw, assigned_dtz, assigned_cp,
               computed_result, computed_dtw, computed_dtz, computed_cp
        FROM positions
        WHERE id > ? AND (computed_result IS NOT NULL OR computed_cp IS NOT NULL)
        ORDER BY id
        LIMIT ?;
      ''', [afterId, limit]);
    }
  }

  /// Solves the entire database using the flat typed-memory CSR Tarjan solver.
  Future<CsrSolveResult> solveGlobalCsr({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (_db == null) {
      throw StateError('Database is not initialized.');
    }
    await flush();
    return await CsrGraphSolver.solveDirect(_db!, onProgress: onProgress);
  }

  Future<List<Map<String, dynamic>>> loadNodes() async {
    if (_db == null) return [];
    // Load evaluated repertoire nodes (assigned or computed evaluations present)
    final rows = await _db!.rawQuery('''
      SELECT * FROM positions
      WHERE assigned_result IS NOT NULL
         OR computed_result IS NOT NULL
         OR assigned_cp IS NOT NULL
         OR computed_cp IS NOT NULL;
    ''');
    for (final row in rows) {
      final id = row['id'] as int;
      final bfen = row['bfen'] as String;
      _bfenToId[bfen] = id;
      _idToBfen[id] = bfen;
    }
    return rows;
  }

  Future<void> _ensureAllPositionsLoaded() async {
    if (_db == null) return;
    final countResult = await _db!.rawQuery('SELECT COUNT(1) as cnt FROM positions;');
    final totalPositions = (countResult.first['cnt'] as num).toInt();
    if (_idToBfen.length >= totalPositions) return;

    final rows = await _db!.rawQuery('SELECT id, bfen FROM positions;');
    for (final row in rows) {
      final id = row['id'] as int;
      final bfen = row['bfen'] as String;
      _idToBfen[id] = bfen;
      _bfenToId[bfen] = id;
    }
  }

  Future<List<Map<String, dynamic>>> loadEdges({
    void Function(String source, String target)? onEdge,
  }) async {
    if (_db == null) return [];

    await _ensureAllPositionsLoaded();

    if (onEdge != null) {
      // Keyset streaming to keep memory footprint minimal
      int? lastSourceId;
      int? lastTargetId;
      const chunkSize = 200000;

      while (true) {
        List<Map<String, Object?>> chunk;
        if (lastSourceId == null || lastTargetId == null) {
          chunk = await _db!.rawQuery('''
            SELECT source_id, target_id FROM edges
            ORDER BY source_id, target_id
            LIMIT ?;
          ''', [chunkSize]);
        } else {
          chunk = await _db!.rawQuery('''
            SELECT source_id, target_id FROM edges
            WHERE (source_id > ?) OR (source_id = ? AND target_id > ?)
            ORDER BY source_id, target_id
            LIMIT ?;
          ''', [lastSourceId, lastSourceId, lastTargetId, chunkSize]);
        }

        if (chunk.isEmpty) break;

        for (final row in chunk) {
          final sId = row['source_id'] as int;
          final tId = row['target_id'] as int;
          final s = _idToBfen[sId];
          final t = _idToBfen[tId];
          if (s != null && t != null) {
            onEdge(s, t);
          }
          lastSourceId = sId;
          lastTargetId = tId;
        }

        if (chunk.length < chunkSize) break;
      }
      return const [];
    } else {
      final result = <Map<String, dynamic>>[];
      await loadEdges(onEdge: (s, t) {
        result.add({'source': s, 'target': t});
      });
      return result;
    }
  }

  Future<void> clearDatabase() async {
    if (_db == null) return;
    await _db!.delete('positions');
    await _db!.delete('edges');
    _bfenToId.clear();
    _idToBfen.clear();
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
    _bfenToId.clear();
    _idToBfen.clear();
  }
}
