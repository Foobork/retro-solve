// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/polyglot_book.dart';
import 'package:retro_solve/graph/polyglot_zobrist.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main(List<String> args) async {
  final bookPath = args.isNotEmpty ? args[0] : 'C:/vscode/tolius/e3_c5_up.bin';
  final dbPath = args.length > 1 ? args[1] : 'data/Antichess.db';
  final rootFen = args.length > 2
      ? args[2]
      : 'rnbqkbnr/pp1ppppp/8/2p5/8/4P3/PPPP1PPP/RNBQKBNR w - - 0 2';

  final bookFile = File(bookPath).absolute;
  if (!bookFile.existsSync()) {
    print('Error: Book file not found at ${bookFile.path}');
    exit(1);
  }

  final dbFile = File(dbPath).absolute;
  if (!dbFile.existsSync()) {
    print('Error: Database file not found at ${dbFile.path}');
    exit(1);
  }

  print('========================================================');
  print('Polyglot Book Importer for $dbPath');
  print('Book: ${bookFile.path} (${bookFile.lengthSync()} bytes)');
  print('Root: $rootFen');
  print('========================================================');

  final swTotal = Stopwatch()..start();

  print('Loading Polyglot opening book into memory...');
  final book = PolyglotBook.fromFile(bookFile.path);
  print('Loaded ${book.numEntries} book entries.');

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(dbFile.path);
  await db.execute('PRAGMA journal_mode = WAL;');
  await db.execute('PRAGMA synchronous = NORMAL;');
  await db.execute('PRAGMA cache_size = -64000;'); // 64 MB cache

  print('Loading existing positions (bfen -> id, dtw) from database...');
  final swLoad = Stopwatch()..start();
  final bfenToId = <String, int>{};
  final bfenToDtw = <String, int?>{};
  int lastId = 0;
  const chunk = 250000;

  while (true) {
    final rows = await db.rawQuery(
      'SELECT id, bfen, assigned_dtw FROM positions WHERE id > ? ORDER BY id ASC LIMIT ?',
      [lastId, chunk],
    );
    if (rows.isEmpty) break;
    for (final r in rows) {
      final id = r['id'] as int;
      final bfen = r['bfen'] as String;
      final dtw = r['assigned_dtw'] as int?;
      bfenToId[bfen] = id;
      bfenToDtw[bfen] = dtw;
      if (id > lastId) lastId = id;
    }
  }
  swLoad.stop();
  print('Loaded ${bfenToId.length} existing positions in ${swLoad.elapsedMilliseconds} ms.');

  // Traversal state
  final queue = <String>[rootFen];
  final enqueued = <String>{rootFen};
  int head = 0;

  int newPositionsCount = 0;
  int updatedDtwCount = 0;
  int newEdgesCount = 0;

  final pendingPosInserts = <Map<String, dynamic>>[];
  final pendingPosUpdates = <(int id, int dtw)>[];
  final pendingEdges = <(String srcBfen, String tgtBfen)>[];

  Future<void> flushPositions() async {
    if (pendingPosInserts.isEmpty && pendingPosUpdates.isEmpty) return;

    await db.transaction((txn) async {
      // 1. Batch insert new positions
      if (pendingPosInserts.isNotEmpty) {
        final batch = txn.batch();
        for (final p in pendingPosInserts) {
          batch.rawInsert(
            'INSERT INTO positions (bfen, assigned_result, assigned_dtw, proof_status, pn, dn) VALUES (?, ?, ?, 0, 1, 1)',
            [p['bfen'], p['assigned_result'], p['assigned_dtw']],
          );
        }
        final results = await batch.commit(noResult: false);
        for (int i = 0; i < pendingPosInserts.length; i++) {
          final newId = results[i] as int;
          final bfen = pendingPosInserts[i]['bfen'] as String;
          final dtw = pendingPosInserts[i]['assigned_dtw'] as int?;
          bfenToId[bfen] = newId;
          bfenToDtw[bfen] = dtw;
          newPositionsCount++;
        }
        pendingPosInserts.clear();
      }

      // 2. Batch update existing DTWs with tighter bounds
      if (pendingPosUpdates.isNotEmpty) {
        final batch = txn.batch();
        for (final u in pendingPosUpdates) {
          batch.rawUpdate(
            'UPDATE positions SET assigned_dtw = ? WHERE id = ?',
            [u.$2, u.$1],
          );
          updatedDtwCount++;
        }
        await batch.commit(noResult: true);
        pendingPosUpdates.clear();
      }
    });
  }

  Future<void> flushEdges() async {
    if (pendingEdges.isEmpty) return;
    await flushPositions(); // Ensure IDs exist for all BFENs

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final e in pendingEdges) {
        final srcId = bfenToId[e.$1];
        final tgtId = bfenToId[e.$2];
        if (srcId != null && tgtId != null) {
          batch.rawInsert(
            'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?)',
            [srcId, tgtId],
          );
          newEdgesCount++;
        }
      }
      await batch.commit(noResult: true);
    });
    pendingEdges.clear();
  }

  print('Starting BFS tree traversal from root...');
  final swBfs = Stopwatch()..start();

  while (head < queue.length) {
    final fen = queue[head++];
    final game = AntichessChess();
    game.load(fen);
    final bfen = game.bfen;
    final isWhite = game.turn == PlayerColor.white;

    if (isWhite) {
      final key = PolyglotZobrist.computeKey(fen);
      final entry = book.probe(key);

      if (entry != null) {
        final targetDtw = entry.dtwPlies;

        // Position tracking
        final existingId = bfenToId[bfen];
        if (existingId == null) {
          pendingPosInserts.add({
            'bfen': bfen,
            'assigned_result': 1,
            'assigned_dtw': targetDtw,
          });
          // Temporary placeholder until flushed
          bfenToId[bfen] = -1;
          bfenToDtw[bfen] = targetDtw;
        } else if (existingId > 0) {
          final curDtw = bfenToDtw[bfen];
          if (curDtw == null || targetDtw < curDtw) {
            pendingPosUpdates.add((existingId, targetDtw));
            bfenToDtw[bfen] = targetDtw;
          }
        }

        // Apply winning move
        final legalMoves = game.generateMoves();
        Move? matched;
        for (final m in legalMoves) {
          final u =
              '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ""}';
          if (u == entry.uci) {
            matched = m;
            break;
          }
        }

        if (matched != null) {
          game.makeMove(matched);
          final childFen = game.fen;
          final childBfen = game.bfen;
          pendingEdges.add((bfen, childBfen));

          if (enqueued.add(childFen)) {
            queue.add(childFen);
          }
        }
      } else {
        // Non-book node: only assign dtw = 0 if it is a TRUE terminal position in Antichess
        final isTerminal = game.hasNoPieces(PlayerColor.white) ||
            game.hasNoPieces(PlayerColor.black) ||
            game.generateMoves().isEmpty;
        final existingId = bfenToId[bfen];
        if (existingId == null) {
          pendingPosInserts.add({
            'bfen': bfen,
            'assigned_result': 1,
            'assigned_dtw': isTerminal ? 0 : null,
          });
          bfenToId[bfen] = -1;
          bfenToDtw[bfen] = isTerminal ? 0 : null;
        }
      }
    } else {
      // Black node (Defender): in a White-winning book, White still wins (assigned_result = 1)
      final existingId = bfenToId[bfen];
      if (existingId == null) {
        pendingPosInserts.add({
          'bfen': bfen,
          'assigned_result': 1,
          'assigned_dtw': null,
        });
        bfenToId[bfen] = -1;
        bfenToDtw[bfen] = null;
      }

      final legalMoves = game.generateMoves();
      for (final m in legalMoves) {
        game.makeMove(m);
        final childFen = game.fen;
        final childBfen = game.bfen;
        pendingEdges.add((bfen, childBfen));

        if (enqueued.add(childFen)) {
          queue.add(childFen);
        }
        game.undo();
      }
    }

    // Flush periodically
    if (pendingPosInserts.length >= 5000 || pendingPosUpdates.length >= 5000) {
      await flushPositions();
    }
    if (pendingEdges.length >= 10000) {
      await flushEdges();
    }

    if (head % 25000 == 0 || head == queue.length) {
      final elapsedSec = max(swBfs.elapsedMilliseconds / 1000, 0.001);
      final rate = (head / elapsedSec).toStringAsFixed(0);
      print(
        'Processed: $head / ${queue.length} | In DB: +$newPositionsCount new, ~$updatedDtwCount updated | Edges: +$newEdgesCount ($rate pos/s)',
      );
    }
  }

  // Final flush
  await flushPositions();
  await flushEdges();

  // Propagate DTW upwards to Black (defender) nodes where all children have known DTWs
  print('Propagating DTW to Black positions...');
  final swBlack = Stopwatch()..start();
  final blackResult = await db.rawUpdate('''
    UPDATE positions
    SET assigned_dtw = sub.new_dtw
    FROM (
      SELECT p.id, MAX(c.assigned_dtw) + 1 AS new_dtw
      FROM positions p
      JOIN edges e ON p.id = e.source_id
      JOIN positions c ON e.target_id = c.id
      WHERE p.bfen LIKE '% b - -'
      GROUP BY p.id
      HAVING COUNT(e.target_id) = COUNT(c.assigned_dtw)
         AND (p.assigned_dtw IS NULL OR (MAX(c.assigned_dtw) + 1) < p.assigned_dtw)
    ) AS sub
    WHERE positions.id = sub.id
  ''');
  print('Tightened DTW for $blackResult Black positions in ${swBlack.elapsedMilliseconds} ms.');

  swBfs.stop();
  swTotal.stop();

  print('========================================================');
  print('Import Completed Successfully!');
  print('Total positions traversed: ${queue.length}');
  print('New positions inserted:    $newPositionsCount');
  print('Existing positions updated: $updatedDtwCount');
  print('New edges created:         $newEdgesCount');
  print('Time taken:                ${swTotal.elapsedMilliseconds / 1000} seconds');
  print('========================================================');

  await db.close();
}
