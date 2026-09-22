import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/position_eval.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:retro_solve/persistence/db_init.dart';
import 'package:sqflite_common/sqlite_api.dart';

PositionEval? parseEvalFromRow(Map<String, dynamic> row, String prefix) {
  final resVal = row['${prefix}_result'] as int?;
  final dtw = row['${prefix}_dtw'] as int?;
  final cp = row['${prefix}_cp'] as int?;
  if (resVal == null && dtw == null && cp == null) return null;
  return PositionEval(result: GameResult.fromInt(resVal), dtw: dtw, cp: cp);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('rs_db_test_');
    dbPath = '${tempDir.path}/test_database.db';
  });

  tearDown(() async {
    try {
      final dbService = DatabaseService.instance;
      await dbService.close();
    } catch (_) {}
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  test('DatabaseService creates version 5 normalized schema on fresh init', () async {
    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);
    await dbService.close();

    final factory = getPlatformDatabaseFactory();
    final db = await factory.openDatabase(dbPath);

    // Verify positions table
    final posInfo = await db.rawQuery("PRAGMA table_info('positions');");
    final posCols = {
      for (var col in posInfo) (col['name'] as String).toLowerCase(): (col['type'] as String).toUpperCase()
    };
    expect(posCols['id'], equals('INTEGER'));
    expect(posCols['bfen'], equals('TEXT'));
    expect(posCols['assigned_result'], equals('INTEGER'));
    expect(posCols['assigned_dtw'], equals('INTEGER'));
    expect(posCols['assigned_cp'], equals('INTEGER'));
    expect(posCols['computed_result'], equals('INTEGER'));
    expect(posCols['computed_dtw'], equals('INTEGER'));
    expect(posCols['computed_cp'], equals('INTEGER'));
    expect(posCols.containsKey('assigned_dtz'), isFalse);
    expect(posCols.containsKey('computed_dtz'), isFalse);

    // Verify edges table
    final edgeInfo = await db.rawQuery("PRAGMA table_info('edges');");
    final edgeCols = {
      for (var col in edgeInfo) (col['name'] as String).toLowerCase(): (col['type'] as String).toUpperCase()
    };
    expect(edgeCols['source_id'], equals('INTEGER'));
    expect(edgeCols['target_id'], equals('INTEGER'));
    expect(edgeCols.containsKey('source'), isFalse);
    expect(edgeCols.containsKey('target'), isFalse);

    // Verify reverse index
    final indexInfo = await db.rawQuery("PRAGMA index_list('edges');");
    final indexNames = indexInfo.map((r) => r['name'] as String).toSet();
    expect(indexNames.contains('idx_edges_target'), isTrue);

    // Legacy nodes table must NOT exist
    final tables = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table';"))
        .map((r) => r['name'] as String)
        .toSet();
    expect(tables.contains('nodes'), isFalse);

    await db.close();
  });

  test('DatabaseService persists and loads PositionEval nodes and edges accurately with streaming', () async {
    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);

    const bfen1 = '8/8/5K2/p1p4p/7p/8/8/6r1 b - -';
    const eval1 = PositionEval(result: GameResult.blackWins, dtw: 1);

    const bfen2 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    const eval2 = PositionEval(cp: 25);

    dbService.upsertNode(bfen1, eval1, null);
    dbService.upsertNode(bfen2, null, eval2);
    dbService.upsertEdge(bfen1, bfen2);
    await dbService.flush();

    final loaded = await dbService.loadNodes();
    expect(loaded.length, equals(2));

    final row1 = loaded.firstWhere((r) => r['bfen'] == bfen1);
    expect(parseEvalFromRow(row1, 'assigned'), equals(eval1));
    expect(parseEvalFromRow(row1, 'computed'), isNull);

    final row2 = loaded.firstWhere((r) => r['bfen'] == bfen2);
    expect(parseEvalFromRow(row2, 'assigned'), isNull);
    expect(parseEvalFromRow(row2, 'computed'), equals(eval2));

    // Test loadEdges normal
    final edges = await dbService.loadEdges();
    expect(edges.length, equals(1));
    expect(edges.first['source'], equals(bfen1));
    expect(edges.first['target'], equals(bfen2));

    // Test loadEdges streaming
    final streamedEdges = <Map<String, String>>[];
    await dbService.loadEdges(onEdge: (s, t) {
      streamedEdges.add({'source': s, 'target': t});
    });
    expect(streamedEdges.length, equals(1));
    expect(streamedEdges.first['source'], equals(bfen1));
    expect(streamedEdges.first['target'], equals(bfen2));
  });

  test('DatabaseService seamlessly migrates legacy v2 schema (REAL columns, text edges) to v5', () async {
    final factory = getPlatformDatabaseFactory();

    final legacyDb = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE nodes (
              bfen TEXT PRIMARY KEY,
              assigned REAL,
              computed REAL
            );
          ''');
          await db.execute('''
            CREATE TABLE edges (
              source TEXT,
              target TEXT,
              PRIMARY KEY (source, target)
            );
          ''');
        },
      ),
    );

    await legacyDb.insert('nodes', {'bfen': 'pos1', 'assigned': 999.0, 'computed': null});
    await legacyDb.insert('nodes', {'bfen': 'pos2', 'assigned': null, 'computed': -947.0});
    await legacyDb.insert('nodes', {'bfen': 'pos3', 'assigned': 1.50, 'computed': 1.50});
    await legacyDb.insert('nodes', {'bfen': 'pos4', 'assigned': 0.0, 'computed': null});
    await legacyDb.insert('edges', {'source': 'pos1', 'target': 'pos2'});
    await legacyDb.insert('edges', {'source': 'pos2', 'target': 'pos3'});
    await legacyDb.close();

    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);

    final loaded = await dbService.loadNodes();
    expect(loaded.length, equals(4));

    final p1 = loaded.firstWhere((r) => r['bfen'] == 'pos1');
    expect(parseEvalFromRow(p1, 'assigned'), equals(const PositionEval(result: GameResult.whiteWins, dtw: 1)));

    final p2 = loaded.firstWhere((r) => r['bfen'] == 'pos2');
    expect(parseEvalFromRow(p2, 'computed'), equals(const PositionEval(result: GameResult.blackWins)));

    final p3 = loaded.firstWhere((r) => r['bfen'] == 'pos3');
    expect(parseEvalFromRow(p3, 'assigned'), equals(const PositionEval(cp: 150)));
    expect(parseEvalFromRow(p3, 'computed'), equals(const PositionEval(cp: 150)));

    final p4 = loaded.firstWhere((r) => r['bfen'] == 'pos4');
    expect(parseEvalFromRow(p4, 'assigned'), equals(const PositionEval(cp: 0)));

    final edges = await dbService.loadEdges();
    expect(edges.length, equals(2));
    expect(edges.any((e) => e['source'] == 'pos1' && e['target'] == 'pos2'), isTrue);
    expect(edges.any((e) => e['source'] == 'pos2' && e['target'] == 'pos3'), isTrue);

    await dbService.close();

    // Verify v5 schema on disk without dtz columns
    final db = await factory.openDatabase(dbPath);
    final tables = (await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table';"))
        .map((r) => r['name'] as String)
        .toSet();
    expect(tables.contains('nodes'), isFalse);
    expect(tables.contains('positions'), isTrue);
    expect(tables.contains('edges'), isTrue);

    final posInfo = await db.rawQuery("PRAGMA table_info('positions');");
    final posCols = posInfo.map((r) => (r['name'] as String).toLowerCase()).toSet();
    expect(posCols.contains('assigned_dtz'), isFalse);
    expect(posCols.contains('computed_dtz'), isFalse);
    await db.close();
  });

  test('DatabaseService seamlessly migrates v3 schema (integer columns, text edges) to v5', () async {
    final factory = getPlatformDatabaseFactory();

    final v3Db = await factory.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE nodes (
              bfen TEXT PRIMARY KEY,
              assigned_result INTEGER,
              assigned_dtw INTEGER,
              assigned_cp INTEGER,
              computed_result INTEGER,
              computed_dtw INTEGER,
              computed_cp INTEGER
            );
          ''');
          await db.execute('''
            CREATE TABLE edges (
              source TEXT,
              target TEXT,
              PRIMARY KEY (source, target)
            );
          ''');
        },
      ),
    );

    await v3Db.insert('nodes', {
      'bfen': 'v3_pos1',
      'assigned_result': GameResult.whiteWins.value,
      'assigned_dtw': 1,
      'assigned_cp': null,
      'computed_result': null,
      'computed_dtw': null,
      'computed_cp': null,
    });
    await v3Db.insert('edges', {'source': 'v3_pos1', 'target': 'frontier_target'});
    await v3Db.close();

    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);

    final loaded = await dbService.loadNodes();
    expect(loaded.length, equals(1));
    expect(loaded.first['bfen'], equals('v3_pos1'));

    final edges = await dbService.loadEdges();
    expect(edges.length, equals(1));
    expect(edges.first['source'], equals('v3_pos1'));
    expect(edges.first['target'], equals('frontier_target'));

    await dbService.close();

    final db = await factory.openDatabase(dbPath);
    final posCount = (await db.rawQuery('SELECT COUNT(1) as cnt FROM positions;')).first['cnt'] as int;
    expect(posCount, equals(2));
    await db.close();
  });

  test('DatabaseService seamlessly migrates v4 schema (with assigned_dtz, computed_dtz) to v5', () async {
    final factory = getPlatformDatabaseFactory();

    final v4Db = await factory.openDatabase(
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
        },
      ),
    );

    await v4Db.insert('positions', {
      'bfen': 'v4_pos1',
      'assigned_result': GameResult.blackWins.value,
      'assigned_dtw': null,
      'assigned_dtz': 3,
      'assigned_cp': null,
      'computed_result': GameResult.whiteWins.value,
      'computed_dtw': 2,
      'computed_dtz': 1,
      'computed_cp': null,
    });
    await v4Db.close();

    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);

    final loaded = await dbService.loadNodes();
    expect(loaded.length, equals(1));
    final pos1 = loaded.first;
    expect(parseEvalFromRow(pos1, 'assigned'), equals(const PositionEval(result: GameResult.blackWins)));
    expect(parseEvalFromRow(pos1, 'computed'), equals(const PositionEval(result: GameResult.whiteWins, dtw: 2)));

    await dbService.close();

    final db = await factory.openDatabase(dbPath);
    final posInfo = await db.rawQuery("PRAGMA table_info('positions');");
    final posCols = posInfo.map((r) => (r['name'] as String).toLowerCase()).toSet();
    expect(posCols.contains('assigned_dtz'), isFalse);
    expect(posCols.contains('computed_dtz'), isFalse);
    expect(posCols.contains('assigned_dtw'), isTrue);
    expect(posCols.contains('computed_dtw'), isTrue);
    await db.close();
  });
}
