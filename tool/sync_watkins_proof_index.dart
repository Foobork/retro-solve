// ignore_for_file: avoid_print

import 'dart:io';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/watkins_proof_index.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : 'data/Antichess.db';
  final sw = Stopwatch()..start();

  WatkinsProofIndexManager.instance.refresh();
  if (!WatkinsProofIndexManager.instance.hasIndices) {
    print('No *.proof.idx files found.');
    return;
  }

  sqfliteFfiInit();
  final dbFile = File(dbPath).absolute;
  print('Opening SQLite database: ${dbFile.path}');
  final db = await databaseFactoryFfi.openDatabase(dbFile.path);
  await db.execute('PRAGMA journal_mode = WAL;');
  await db.execute('PRAGMA synchronous = NORMAL;');

  // Ensure 1. e3 c5 -> 2. Bb5 and all 21 replies to 2. Bb5 exist in Antichess.db
  final game = AntichessChess();
  game.move('e3');
  final e3Bfen = game.bfen;
  game.move('c5');
  final c5Bfen = game.bfen;
  game.move('Bb5');
  final bb5Bfen = game.bfen;

  final rootBfensToEnsure = <String>[e3Bfen, c5Bfen, bb5Bfen];
  final rootEdgesToEnsure = <(String, String)>[(e3Bfen, c5Bfen), (c5Bfen, bb5Bfen)];

  for (final m in game.generateMoves()) {
    game.makeMove(m);
    final replyBfen = game.bfen;
    rootBfensToEnsure.add(replyBfen);
    rootEdgesToEnsure.add((bb5Bfen, replyBfen));
    game.undoMove();
  }

  for (final bfen in rootBfensToEnsure) {
    await db.rawInsert('INSERT OR IGNORE INTO positions (bfen) VALUES (?);', [bfen]);
  }
  for (final edge in rootEdgesToEnsure) {
    final sRow = await db.rawQuery('SELECT id FROM positions WHERE bfen = ?;', [edge.$1]);
    final tRow = await db.rawQuery('SELECT id FROM positions WHERE bfen = ?;', [edge.$2]);
    if (sRow.isNotEmpty && tRow.isNotEmpty) {
      await db.rawInsert(
        'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);',
        [sRow.first['id'], tRow.first['id']],
      );
    }
  }

  print('Scanning positions in DB against Watkins *.proof.idx files...');
  final candidates = <(int, int)>[]; // (hash, id)
  int lastId = 0;
  const chunkSize = 100000;
  int scanned = 0;

  while (true) {
    final rows = await db.rawQuery('''
      SELECT id, bfen, assigned_dtw, computed_dtw
      FROM positions
      WHERE id > ?
      ORDER BY id
      LIMIT ?;
    ''', [lastId, chunkSize]);
    if (rows.isEmpty) break;

    for (final row in rows) {
      final id = row['id'] as int;
      final bfen = row['bfen'] as String;
      final assignedDtw = row['assigned_dtw'] as int?;
      final computedDtw = row['computed_dtw'] as int?;
      lastId = id;
      scanned++;

      if (assignedDtw != null || computedDtw != null) continue;
      candidates.add((WatkinsZobrist.hashBfen(bfen), id));
    }
    if (rows.length < chunkSize) break;
  }

  print('Sorting ${candidates.length} unproven DB hashes for sequential index scan...');
  candidates.sort((a, b) => (a.$1 >>> 48).compareTo(b.$1 >>> 48));

  final updates = <(int, int)>[]; // (id, dtw)
  for (final cand in candidates) {
    final entry = WatkinsProofIndexManager.instance.lookupHash(cand.$1);
    if (entry != null) {
      updates.add((cand.$2, entry.dtw));
    }
  }
  updates.sort((a, b) => a.$1.compareTo(b.$1));

  print('Scanned $scanned DB positions; found ${updates.length} matches in *.proof.idx.');

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
            SET assigned_result = 1,
                assigned_dtw = ?,
                assigned_cp = NULL,
                computed_result = 1,
                computed_dtw = ?,
                computed_cp = NULL,
                proof_status = 1,
                pn = 0,
                dn = 1000000000
            WHERE id = ?;
            ''',
            [u.$2, u.$2, u.$1],
          );
        }
        await batch.commit(noResult: true);
      });
    }
    print('Updated ${updates.length} positions in DB.');
  }

  await db.close();
  print('Sync completed in ${sw.elapsedMilliseconds}ms.');
}
