import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/position_eval.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:retro_solve/persistence/db_init.dart';
import 'package:sqflite_common/sqlite_api.dart';

PositionEval? parseEvalFromRow(Map<String, dynamic> row, String prefix) {
  final resVal = row['${prefix}_result'] as int?;
  final dtw = row['${prefix}_dtw'] as int?;
  final dtz = row['${prefix}_dtz'] as int?;
  final cp = row['${prefix}_cp'] as int?;
  if (resVal == null && dtw == null && dtz == null && cp == null) return null;
  return PositionEval(result: GameResult.fromInt(resVal), dtw: dtw, dtz: dtz, cp: cp);
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

  test('DatabaseService creates version 3 pure integer schema on fresh init', () async {
    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);
    await dbService.close();

    final factory = getPlatformDatabaseFactory();
    final db = await factory.openDatabase(dbPath);

    final tableInfo = await db.rawQuery("PRAGMA table_info('nodes');");
    final columns = {
      for (var col in tableInfo) (col['name'] as String).toLowerCase(): (col['type'] as String).toUpperCase()
    };

    // Verify presence of all pure integer columns
    expect(columns['bfen'], equals('TEXT'));
    expect(columns['assigned_result'], equals('INTEGER'));
    expect(columns['assigned_dtw'], equals('INTEGER'));
    expect(columns['assigned_dtz'], equals('INTEGER'));
    expect(columns['assigned_cp'], equals('INTEGER'));
    expect(columns['computed_result'], equals('INTEGER'));
    expect(columns['computed_dtw'], equals('INTEGER'));
    expect(columns['computed_dtz'], equals('INTEGER'));
    expect(columns['computed_cp'], equals('INTEGER'));

    // Legacy REAL columns must NOT exist
    expect(columns.containsKey('assigned'), isFalse);
    expect(columns.containsKey('computed'), isFalse);

    await db.close();
  });

  test('DatabaseService persists and loads PositionEval nodes accurately', () async {
    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);

    const bfen1 = '8/8/5K2/p1p4p/7p/8/8/6r1 b - -';
    const eval1 = PositionEval(result: GameResult.blackWins, dtz: 1);

    const bfen2 = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    const eval2 = PositionEval(cp: 25);

    dbService.upsertNode(bfen1, eval1, null);
    dbService.upsertNode(bfen2, null, eval2);
    await dbService.flush();

    final loaded = await dbService.loadNodes();
    expect(loaded.length, equals(2));

    final row1 = loaded.firstWhere((r) => r['bfen'] == bfen1);
    expect(parseEvalFromRow(row1, 'assigned'), equals(eval1));
    expect(parseEvalFromRow(row1, 'computed'), isNull);

    final row2 = loaded.firstWhere((r) => r['bfen'] == bfen2);
    expect(parseEvalFromRow(row2, 'assigned'), isNull);
    expect(parseEvalFromRow(row2, 'computed'), equals(eval2));
  });

  test('DatabaseService seamlessly migrates legacy v2 schema with REAL columns to v3 pure integers', () async {
    final factory = getPlatformDatabaseFactory();

    // 1. Manually construct a legacy v2 SQLite database with REAL columns
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

    // Insert legacy float scores
    // 999.0 -> Mate in 1 for White (dtw: 1)
    await legacyDb.insert('nodes', {'bfen': 'pos1', 'assigned': 999.0, 'computed': null});
    // -947.0 -> DTZ 3 for Black (dtz: 3, blackWins)
    await legacyDb.insert('nodes', {'bfen': 'pos2', 'assigned': null, 'computed': -947.0});
    // 1.50 -> Heuristic +1.50 (cp: 150)
    await legacyDb.insert('nodes', {'bfen': 'pos3', 'assigned': 1.50, 'computed': 1.50});
    // 0.0 -> Draw
    await legacyDb.insert('nodes', {'bfen': 'pos4', 'assigned': 0.0, 'computed': null});

    await legacyDb.close();

    // 2. Open via DatabaseService.init() which triggers automated migration to v3
    final dbService = DatabaseService.instance;
    await dbService.init(dbPath);

    // 3. Inspect data: verify accurate reconstruction into PositionEval
    final loaded = await dbService.loadNodes();
    expect(loaded.length, equals(4));

    final p1 = loaded.firstWhere((r) => r['bfen'] == 'pos1');
    expect(parseEvalFromRow(p1, 'assigned'), equals(const PositionEval(result: GameResult.whiteWins, dtw: 1)));

    final p2 = loaded.firstWhere((r) => r['bfen'] == 'pos2');
    expect(parseEvalFromRow(p2, 'computed'), equals(const PositionEval(result: GameResult.blackWins, dtz: 3)));

    final p3 = loaded.firstWhere((r) => r['bfen'] == 'pos3');
    expect(parseEvalFromRow(p3, 'assigned'), equals(const PositionEval(cp: 150)));
    expect(parseEvalFromRow(p3, 'computed'), equals(const PositionEval(cp: 150)));

    final p4 = loaded.firstWhere((r) => r['bfen'] == 'pos4');
    expect(parseEvalFromRow(p4, 'assigned'), equals(const PositionEval(result: GameResult.draw, cp: 0)));

    await dbService.close();

    // 4. Inspect schema: legacy REAL columns must be completely dropped
    final db = await factory.openDatabase(dbPath);
    final tableInfo = await db.rawQuery("PRAGMA table_info('nodes');");
    final columns = {
      for (var col in tableInfo) (col['name'] as String).toLowerCase(): (col['type'] as String).toUpperCase()
    };
    expect(columns.containsKey('assigned'), isFalse);
    expect(columns.containsKey('computed'), isFalse);
    expect(columns['assigned_result'], equals('INTEGER'));
    expect(columns['computed_result'], equals('INTEGER'));
    await db.close();
  });
}
