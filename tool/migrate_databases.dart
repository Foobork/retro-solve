// ignore_for_file: avoid_print

import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> migrateDatabase(String dbPath) async {
  sqfliteFfiInit();
  final file = File(dbPath).absolute;
  if (!file.existsSync()) {
    print('Database file not found: ${file.path}');
    return;
  }
  final absPath = file.path;
  final initialSize = file.lengthSync();
  print('====================================================');
  print('Starting batch migration for: $absPath');
  print('Initial size: $initialSize bytes (${(initialSize / (1024 * 1024)).toStringAsFixed(2)} MB)');

  final stopwatch = Stopwatch()..start();
  final db = await databaseFactoryFfi.openDatabase(absPath);

  // Performance pragmas for bulk offline migration
  await db.execute('PRAGMA synchronous = OFF;');
  await db.execute('PRAGMA temp_store = MEMORY;');
  await db.execute('PRAGMA cache_size = -2097152;'); // 2 GB cache in RAM

  final posInfo = await db.rawQuery("PRAGMA table_info('positions');");
  final colNames = posInfo.map((r) => (r['name'] as String?)?.toLowerCase()).toSet();

  final hasDtz = colNames.contains('assigned_dtz') || colNames.contains('computed_dtz');
  if (hasDtz) {
    print('Found DTZ columns. Performing single-pass copy-and-swap in RAM...');
    final copyWatch = Stopwatch()..start();

    await db.execute('BEGIN EXCLUSIVE TRANSACTION;');

    // 1. Create new table without DTZ
    await db.execute('''
      CREATE TABLE positions_v5 (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        bfen TEXT UNIQUE NOT NULL,
        assigned_result INTEGER,
        assigned_dtw INTEGER,
        assigned_cp INTEGER,
        computed_result INTEGER,
        computed_dtw INTEGER,
        computed_cp INTEGER
      );
    ''');

    // 2. Copy data across in a single bulk SQL statement
    print('Copying all rows to positions_v5...');
    await db.execute('''
      INSERT INTO positions_v5 (
        id, bfen, assigned_result, assigned_dtw, assigned_cp,
        computed_result, computed_dtw, computed_cp
      )
      SELECT
        id, bfen, assigned_result, assigned_dtw, assigned_cp,
        computed_result, computed_dtw, computed_cp
      FROM positions;
    ''');

    // 3. Drop old table and rename new table into place
    print('Swapping table into place...');
    await db.execute('DROP TABLE positions;');
    await db.execute('ALTER TABLE positions_v5 RENAME TO positions;');

    // 4. Update schema version
    await db.execute('PRAGMA user_version = 5;');

    await db.execute('COMMIT;');
    copyWatch.stop();
    print('Copy-and-swap completed in ${(copyWatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} seconds.');
  } else {
    print('No DTZ columns found. Ensuring user_version = 5...');
    await db.execute('PRAGMA user_version = 5;');
  }

  // Ensure edges table and reverse index exist
  await db.execute('''
    CREATE TABLE IF NOT EXISTS edges (
      source_id INTEGER NOT NULL,
      target_id INTEGER NOT NULL,
      PRIMARY KEY (source_id, target_id)
    ) WITHOUT ROWID;
  ''');
  await db.execute('''
    CREATE INDEX IF NOT EXISTS idx_edges_target ON edges (target_id, source_id);
  ''');

  // Run VACUUM to reclaim disk space
  print('Running VACUUM to defragment and shrink database file...');
  final vacWatch = Stopwatch()..start();
  await db.execute('VACUUM;');
  vacWatch.stop();
  print('VACUUM completed in ${(vacWatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} seconds.');

  final posCount = (await db.rawQuery('SELECT COUNT(1) as cnt FROM positions;')).first['cnt'];
  final edgeCount = (await db.rawQuery('SELECT COUNT(1) as cnt FROM edges;')).first['cnt'];
  await db.close();

  final finalSize = File(absPath).lengthSync();
  final saved = initialSize - finalSize;
  stopwatch.stop();

  print('Migration completed in ${(stopwatch.elapsedMilliseconds / 1000).toStringAsFixed(2)} seconds total.');
  print('Final size: $finalSize bytes (${(finalSize / (1024 * 1024)).toStringAsFixed(2)} MB)');
  print('Space saved: $saved bytes (${(saved / (1024 * 1024)).toStringAsFixed(2)} MB)');
  print('Verified: $posCount positions, $edgeCount edges');
  print('====================================================');
}

void main(List<String> args) async {
  if (args.isNotEmpty) {
    for (final path in args) {
      await migrateDatabase(path);
    }
  } else {
    // Default to migrating all databases in data/
    final dataDir = Directory('data');
    if (!dataDir.existsSync()) {
      print('data directory not found.');
      return;
    }
    final dbFiles = dataDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.db') && !f.path.contains('-wal') && !f.path.contains('-shm'))
        .toList();
    for (final file in dbFiles) {
      await migrateDatabase(file.path);
    }
  }
}
