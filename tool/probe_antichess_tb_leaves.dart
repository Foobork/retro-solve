// ignore_for_file: avoid_print

import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'antichess_tb_ffi.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : 'data/Antichess.db';
  final sw = Stopwatch()..start();

  print('Initializing Antichess 2-4 piece DTW Tablebase Prober...');
  final prober = AntichessTbProber();
  print('Tablebase initialized in ${sw.elapsedMilliseconds}ms.');

  // Quick sanity check on the README test position:
  // 8/8/6R1/8/2N1P3/8/p7/8 b - - -> dtw = -43 (White wins in 43 plies)
  final testRes = prober.probeBfen('8/8/6R1/8/2N1P3/8/p7/8 b - -');
  print(
    'Sanity check (8/8/6R1/8/2N1P3/8/p7/8 b - -): '
    'res=${testRes?.whitePerspectiveResult}, dtw=${testRes?.dtw}, dtz>100=${testRes?.dtzOver100}',
  );
  if (testRes == null || testRes.whitePerspectiveResult != 1 || testRes.dtw != 43) {
    throw StateError('Sanity check failed!');
  }

  sqfliteFfiInit();
  final dbFile = File(dbPath).absolute;
  print('Opening SQLite database: ${dbFile.path}');
  final db = await databaseFactoryFfi.openDatabase(dbFile.path);

  await db.execute('PRAGMA journal_mode = WAL;');
  await db.execute('PRAGMA synchronous = NORMAL;');

  // Query all positions that have assigned_result IS NOT NULL and assigned_dtw IS NULL
  final rows = await db.rawQuery('''
    SELECT id, bfen, assigned_result
    FROM positions
    WHERE assigned_result IS NOT NULL AND assigned_dtw IS NULL;
  ''');

  print('Found ${rows.length} terminal positions with assigned_dtw IS NULL.');

  final updates = <(int, int, int)>[]; // (id, result, dtw)
  int mismatchCount = 0;
  int unprobedCount = 0;
  int maxDtw = 0;
  int minDtw = 999999;

  for (final row in rows) {
    final id = row['id'] as int;
    final bfen = row['bfen'] as String;
    final assignedRes = row['assigned_result'] as int;

    final tbRes = prober.probeBfen(bfen);
    if (tbRes == null || tbRes.dtw == null) {
      unprobedCount++;
      continue;
    }
    if (tbRes.whitePerspectiveResult != assignedRes) {
      mismatchCount++;
      print(
        '  WARNING: Result mismatch on id=$id ($bfen): '
        'DB assigned_result=$assignedRes vs TB=${tbRes.whitePerspectiveResult} (dtw=${tbRes.dtw})',
      );
    }
    final dtw = tbRes.dtw!;
    if (dtw > maxDtw) maxDtw = dtw;
    if (dtw < minDtw) minDtw = dtw;
    updates.add((id, assignedRes, dtw));
  }

  print('Probed ${updates.length} / ${rows.length} leaves:');
  print('  Min DTW: $minDtw plies, Max DTW: $maxDtw plies');
  print('  Result mismatches: $mismatchCount, Unprobed (>4 pieces): $unprobedCount');

  if (updates.isNotEmpty) {
    const batchSize = 5000;
    for (int i = 0; i < updates.length; i += batchSize) {
      final end = (i + batchSize < updates.length) ? i + batchSize : updates.length;
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (int j = i; j < end; j++) {
          final u = updates[j];
          batch.rawUpdate(
            '''
            UPDATE positions
            SET assigned_dtw = ?,
                computed_dtw = ?
            WHERE id = ?;
            ''',
            [u.$3, u.$3, u.$1],
          );
        }
        await batch.commit(noResult: true);
      });
    }
    print('Updated ${updates.length} positions in DB.');
  }

  await db.close();
  prober.dispose();
  print('Done in ${sw.elapsedMilliseconds}ms.');
}
