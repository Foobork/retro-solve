import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NodeUpdate {
  final String bfen;
  final double? assigned;
  final double? computed;
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
  static bool _ffiInitialized = false;

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
    if (Platform.isWindows || Platform.isLinux) {
      if (!_ffiInitialized) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
        _ffiInitialized = true;
      }
    }

    _db = await openDatabase(
      dbPath,
      version: 2,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE nodes (
            bfen TEXT PRIMARY KEY,
            assigned REAL,
            computed REAL
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
      },
    );

    // Failsafe: Ensure tables always exist regardless of migration state (useful during dev)
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS nodes (
        bfen TEXT PRIMARY KEY,
        assigned REAL,
        computed REAL
      )
    ''');
    await _db!.execute('''
      CREATE TABLE IF NOT EXISTS edges (
        source TEXT,
        target TEXT,
        PRIMARY KEY (source, target)
      )
    ''');
  }

  Future<void> upsertNode(String bfen, double? assigned, double? computed) async {
    if (_db == null) return;
    _updateQueue[bfen] = _NodeUpdate(bfen, assigned, computed);
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
              'assigned': update.assigned,
              'computed': update.computed,
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

  Future<void> close() async {
    while (_isFlushing || _updateQueue.isNotEmpty || _edgeQueue.isNotEmpty) {
      if (!_isFlushing && (_updateQueue.isNotEmpty || _edgeQueue.isNotEmpty)) {
        await _flushQueue();
      } else {
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }
    await _db?.close();
    _db = null;
  }
}
