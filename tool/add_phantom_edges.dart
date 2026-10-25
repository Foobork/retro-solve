// ignore_for_file: avoid_print

import 'dart:io';
import 'package:retro_solve/chess/chess.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main(List<String> args) async {
  final dbPath = args.isNotEmpty && !args[0].startsWith('--')
      ? args[0]
      : 'data/Antichess.db';
  final whiteOnly = args.contains('--white-only');
  final swTotal = Stopwatch()..start();

  final dbFile = File(dbPath).absolute;
  if (!dbFile.existsSync()) {
    print('Error: Database file does not exist at ${dbFile.path}');
    exit(1);
  }

  print('========================================================');
  print('Phantom Edge Connector for $dbPath');
  print('Mode: ${whiteOnly ? "White positions only" : "All positions (White & Black)"}');
  print('========================================================');

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(dbFile.path);
  await db.execute('PRAGMA journal_mode = WAL;');
  await db.execute('PRAGMA synchronous = NORMAL;');

  final edgeCountBeforeRow =
      await db.rawQuery('SELECT count(*) as c FROM edges;');
  final edgeCountBefore = edgeCountBeforeRow.first['c'] as int;
  print('Current edges in database: $edgeCountBefore');

  print('Loading positions (bfen -> id) into memory...');
  final swLoad = Stopwatch()..start();
  final bfenToId = <String, int>{};
  int lastId = 0;
  const chunk = 250000;

  while (true) {
    final rows = await db.rawQuery(
      'SELECT id, bfen FROM positions WHERE id > ? ORDER BY id LIMIT ?;',
      [lastId, chunk],
    );
    if (rows.isEmpty) break;
    for (final r in rows) {
      final id = r['id'] as int;
      final bfen = r['bfen'] as String;
      bfenToId[bfen] = id;
      lastId = id;
    }
    if (rows.length < chunk) break;
  }
  print(
    'Loaded ${bfenToId.length} positions in ${swLoad.elapsedMilliseconds}ms.',
  );

  print('Scanning positions for legal moves between existing nodes...');
  final swScan = Stopwatch()..start();
  final game = AntichessChess();
  final pendingEdges = <(int, int)>[];
  int scanned = 0;
  int candidateEdges = 0;
  const batchInsertSize = 10000;

  Future<void> flushEdges() async {
    if (pendingEdges.isEmpty) return;
    final list = List<(int, int)>.from(pendingEdges);
    pendingEdges.clear();

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final pair in list) {
        batch.rawInsert(
          'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);',
          [pair.$1, pair.$2],
        );
      }
      await batch.commit(noResult: true);
    });
  }

  for (final entry in bfenToId.entries) {
    final sourceBfen = entry.key;
    final sourceId = entry.value;

    if (whiteOnly && !sourceBfen.contains(' w ')) {
      continue;
    }

    scanned++;

    try {
      game.load(sourceBfen.contains(' ') ? '$sourceBfen 0 1' : sourceBfen);
    } catch (_) {
      continue;
    }

    if (game.gameOver) continue;

    final moves = game.generateMoves();
    for (int i = 0; i < moves.length; i++) {
      final m = moves[i];
      game.makeMove(m);
      final childBfen = game.bfen;
      game.undo();

      final targetId = bfenToId[childBfen];
      if (targetId != null) {
        candidateEdges++;
        pendingEdges.add((sourceId, targetId));
        if (pendingEdges.length >= batchInsertSize) {
          await flushEdges();
        }
      }
    }

    if (scanned % 50000 == 0) {
      final rate = (scanned / (swScan.elapsedMilliseconds / 1000)).toStringAsFixed(0);
      print(
        '  Scanned $scanned positions ($rate pos/s) | Found $candidateEdges candidate edges...',
      );
    }
  }

  await flushEdges();
  swScan.stop();

  final edgeCountAfterRow =
      await db.rawQuery('SELECT count(*) as c FROM edges;');
  final edgeCountAfter = edgeCountAfterRow.first['c'] as int;
  final newEdgesAdded = edgeCountAfter - edgeCountBefore;

  print('--------------------------------------------------------');
  print('Edge scan complete in ${swScan.elapsedMilliseconds}ms.');
  print('Total candidate connections checked: $candidateEdges');
  print('New phantom edges actually inserted: $newEdgesAdded');
  print('Final total edges in database:       $edgeCountAfter');
  print('Total elapsed time:                  ${swTotal.elapsedMilliseconds}ms');
  print('========================================================');

  await db.close();
}
