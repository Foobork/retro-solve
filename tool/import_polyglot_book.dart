// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:math';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/polyglot_book.dart';
import 'package:retro_solve/graph/polyglot_zobrist.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const Map<String, String> kE3RemainingBooks = {
  'a5': 'e3_a5.bin',
  'a6': 'e3_a6.bin',
  'b5': 'e3_b5_up.bin',
  'b6': 'e3_b6_up.bin',
  'c5': 'e3_c5_up.bin',
  'c6': 'e3_c6_short.bin',
  'd5': 'e3_d5.bin',
  'd6': 'e3_d6.bin',
  'e5': 'e3_e5.bin',
  'e6': 'e3_e6_up.bin',
  'f5': 'e3_f5.bin',
  'f6': 'e3_f6.bin',
  'g5': 'e3_g5_short.bin',
  'g6': 'e3_g6.bin',
  'h5': 'e3_h5.bin',
  'h6': 'e3_h6.bin',
  'Na6': 'e3_Na6.bin',
  'Nc6': 'e3_Nc6_short.bin',
  'Nf6': 'e3_Nf6.bin',
  'Nh6': 'e3_Nh6_short.bin',
};

(String label, String rootFen) inferOpeningFromFilename(String filename) {
  var base = filename;
  if (base.endsWith('.bin')) {
    base = base.substring(0, base.length - 4);
  }
  if (base.endsWith('_up')) {
    base = base.substring(0, base.length - 3);
  } else if (base.endsWith('_short')) {
    base = base.substring(0, base.length - 6);
  }
  final moves = base.split('_');
  final game = AntichessChess();
  for (final m in moves) {
    final ok = game.move(m);
    if (!ok) {
      throw ArgumentError('Could not play move "$m" from filename "$filename"');
    }
  }
  return ('1. ${moves.join(' ')}', game.fen);
}

void main(List<String> args) async {
  final isAllE3 = args.isNotEmpty && args[0] == '--all-e3';
  String dbPath = 'data/Antichess.db';
  final binArgs = <String>[];
  String? customRootFen;

  if (isAllE3) {
    if (args.length > 1) dbPath = args[1];
  } else {
    for (final a in args) {
      if (a.endsWith('.bin')) {
        binArgs.add(a);
      } else if (a.endsWith('.db')) {
        dbPath = a;
      } else if (a.contains('/')) {
        customRootFen = a;
      }
    }
  }

  final dbFile = File(dbPath).absolute;
  if (!dbFile.existsSync()) {
    print('Error: Database file not found at ${dbFile.path}');
    exit(1);
  }

  final jobs = <({String label, File bookFile, String rootFen})>[];
  if (isAllE3) {
    final booksDir = args.length > 2
        ? args[2]
        : 'C:/vscode/tolius/solver/build/Release/books';
    for (final entry in kE3RemainingBooks.entries) {
      final g = AntichessChess();
      g.move('e3');
      g.move(entry.key);
      final f = File('$booksDir/${entry.value}').absolute;
      if (!f.existsSync()) {
        print('Error: Book file not found at ${f.path}');
        exit(1);
      }
      jobs.add((label: '1. e3 ${entry.key}', bookFile: f, rootFen: g.fen));
    }
  } else {
    final paths = binArgs.isNotEmpty
        ? binArgs
        : ['C:/vscode/tolius/e3_c5_up.bin'];
    for (final bookPath in paths) {
      final bookFile = File(bookPath).absolute;
      if (!bookFile.existsSync()) {
        print('Error: Book file not found at ${bookFile.path}');
        exit(1);
      }
      final (inferredLabel, inferredFen) =
          inferOpeningFromFilename(bookFile.uri.pathSegments.last);
      final rootFen = customRootFen ?? inferredFen;
      jobs.add((label: inferredLabel, bookFile: bookFile, rootFen: rootFen));
    }
  }

  print('========================================================');
  print('Polyglot Book Importer for $dbPath (${jobs.length} book(s))');
  print('========================================================');

  final swTotal = Stopwatch()..start();

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

  int newPositionsCount = 0;
  int updatedDtwCount = 0;
  int newEdgesCount = 0;
  int totalTraversed = 0;

  final pendingPosInserts = <Map<String, dynamic>>[];
  final pendingPosUpdates = <(int id, int result, int? dtw)>[];
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
            'UPDATE positions SET assigned_result = ?, assigned_dtw = COALESCE(?, assigned_dtw) WHERE id = ?',
            [u.$2, u.$3, u.$1],
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

    const edgeChunk = 50000;
    for (int i = 0; i < pendingEdges.length; i += edgeChunk) {
      final end = min(i + edgeChunk, pendingEdges.length);
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (int j = i; j < end; j++) {
          final e = pendingEdges[j];
          final srcId = bfenToId[e.$1];
          final tgtId = bfenToId[e.$2];
          if (srcId != null && srcId > 0 && tgtId != null && tgtId > 0) {
            batch.rawInsert(
              'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?)',
              [srcId, tgtId],
            );
            newEdgesCount++;
          }
        }
        await batch.commit(noResult: true);
      });
    }
    pendingEdges.clear();
  }

  final swBfs = Stopwatch()..start();

  for (int jobIdx = 0; jobIdx < jobs.length; jobIdx++) {
    final job = jobs[jobIdx];
    final book = PolyglotBook.fromFile(job.bookFile.path);
    final rootGame = AntichessChess()..load(job.rootFen);
    final rootBfen = rootGame.bfen;
    final attackerIsWhite = rootBfen.contains(' w ');
    final winningResult = attackerIsWhite ? 1 : -1;
    final winnerSideLabel = attackerIsWhite ? 'White (+1)' : 'Black (-1)';

    print(
      '\n[${jobIdx + 1}/${jobs.length}] Importing ${job.label} (${job.bookFile.uri.pathSegments.last}, ${book.numEntries} entries, winner: $winnerSideLabel)...',
    );

    // Queue holds (bfen, parentDtwPlies)
    final queue = <(String bfen, int? parentDtw)>[
      (rootBfen, null),
    ];
    final enqueued = <String>{rootBfen};
    int head = 0;

    while (head < queue.length) {
      final (bfen, parentDtw) = queue[head++];
      final isAttacker = (bfen.contains(' w ') == attackerIsWhite);

      if (isAttacker) {
        final key = PolyglotZobrist.computeKey(bfen);
        final entry = book.probe(key);

        if (entry != null) {
          // Tolius weight encoding (positioninfo.h):
          //   weight > 32577: exact proven mate in (32767 - weight) moves
          //   weight <= 32577: unverified (#N?) or skipped ("Draw?") branch
          final isExactMate = entry.weight > 32577;
          final int? targetRes = isExactMate ? winningResult : null;
          final int? targetDtw = isExactMate ? entry.dtwPlies : null;

          // Position tracking
          final existingId = bfenToId[bfen];
          if (existingId == null) {
            pendingPosInserts.add({
              'bfen': bfen,
              'assigned_result': targetRes,
              'assigned_dtw': targetDtw,
            });
            bfenToId[bfen] = -1;
            bfenToDtw[bfen] = targetDtw;
          } else if (existingId > 0 && targetRes != null) {
            final curDtw = bfenToDtw[bfen];
            if (targetDtw != null &&
                (curDtw == null || targetDtw < curDtw || curDtw.isOdd)) {
              pendingPosUpdates.add((existingId, targetRes, targetDtw));
              bfenToDtw[bfen] = targetDtw;
            } else if (targetDtw == null && curDtw == null) {
              pendingPosUpdates.add((existingId, targetRes, null));
            }
          }

          // Apply winning move
          final game = AntichessChess()..load('$bfen 0 1');
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
            final childBfen = game.bfen;
            pendingEdges.add((bfen, childBfen));

            if (enqueued.add(childBfen)) {
              queue.add((childBfen, isExactMate ? targetDtw : -1));
            }
          }
        } else {
          // Non-book leaf node: can only be a true terminal (dtw=0) if parent was #1 (dtwPlies <= 2)
          bool isTerminal = false;
          if (parentDtw == null || (parentDtw >= 0 && parentDtw <= 2)) {
            final game = AntichessChess()..load('$bfen 0 1');
            isTerminal = game.hasNoPieces(PlayerColor.white) ||
                game.hasNoPieces(PlayerColor.black) ||
                game.generateMoves().isEmpty;
          }
          final leafRes = (parentDtw == -1 && !isTerminal) ? null : winningResult;
          final existingId = bfenToId[bfen];
          if (existingId == null) {
            pendingPosInserts.add({
              'bfen': bfen,
              'assigned_result': leafRes,
              'assigned_dtw': isTerminal ? 0 : null,
            });
            bfenToId[bfen] = -1;
            bfenToDtw[bfen] = isTerminal ? 0 : null;
          } else if (existingId > 0 && isTerminal && bfenToDtw[bfen] == null) {
            pendingPosUpdates.add((existingId, winningResult, 0));
            bfenToDtw[bfen] = 0;
          }
        }
      } else {
        // Defender node: winning side still wins unless parent was a skipped "Draw?" branch (parentDtw == -1)
        final defRes = (parentDtw == -1) ? null : winningResult;
        final existingId = bfenToId[bfen];
        if (existingId == null) {
          pendingPosInserts.add({
            'bfen': bfen,
            'assigned_result': defRes,
            'assigned_dtw': null,
          });
          bfenToId[bfen] = -1;
          bfenToDtw[bfen] = null;
        }

        final game = AntichessChess()..load('$bfen 0 1');
        final legalMoves = game.generateMoves();
        for (final m in legalMoves) {
          game.makeMove(m);
          final childBfen = game.bfen;
          pendingEdges.add((bfen, childBfen));

          if (enqueued.add(childBfen)) {
            queue.add((childBfen, parentDtw));
          }
          game.undo();
        }
      }

      // Flush positions periodically in large batches; edges are flushed once per book after all nodes exist
      if (pendingPosInserts.length >= 25000 || pendingPosUpdates.length >= 25000) {
        await flushPositions();
      }

      if (head % 50000 == 0 || head == queue.length) {
        final elapsedSec = max(swBfs.elapsedMilliseconds / 1000, 0.001);
        final rate = ((totalTraversed + head) / elapsedSec).toStringAsFixed(0);
        print(
          '  [${job.label}] Processed: $head / ${queue.length} | Total DB: +$newPositionsCount new, ~$updatedDtwCount updated | Pending edges: ${pendingEdges.length} ($rate pos/s)',
        );
      }
    }

    totalTraversed += queue.length;
    await flushPositions();
    await flushEdges();
  }

  final hasWhiteBooks =
      jobs.any((j) => (AntichessChess()..load(j.rootFen)).bfen.contains(' w '));
  final hasBlackBooks =
      jobs.any((j) => (AntichessChess()..load(j.rootFen)).bfen.contains(' b '));

  for (final attackerIsWhite in [
    if (hasWhiteBooks) true,
    if (hasBlackBooks) false,
  ]) {
    final winningResult = attackerIsWhite ? 1 : -1;
    final defenderLike = attackerIsWhite ? '% b %' : '% w %';
    final defenderName = attackerIsWhite ? 'Black' : 'White';
    print('\nPropagating DTW to $defenderName (defender) positions...');
    final swDef = Stopwatch()..start();
    final defResult = await db.rawUpdate('''
      UPDATE positions
      SET assigned_result = ?, assigned_dtw = sub.new_dtw
      FROM (
        SELECT p.id, MAX(c.assigned_dtw) + 1 AS new_dtw
        FROM positions p
        JOIN edges e ON p.id = e.source_id
        JOIN positions c ON e.target_id = c.id
        WHERE p.bfen LIKE ?
        GROUP BY p.id
        HAVING COUNT(e.target_id) = COUNT(c.assigned_dtw)
           AND MIN(c.assigned_result) = ? AND MAX(c.assigned_result) = ?
           AND (p.assigned_dtw IS NULL OR (MAX(c.assigned_dtw) + 1) < p.assigned_dtw OR (p.assigned_dtw % 2) = 0)
      ) AS sub
      WHERE positions.id = sub.id
    ''', [winningResult, defenderLike, winningResult, winningResult]);
    print('Tightened DTW for $defResult $defenderName positions in ${swDef.elapsedMilliseconds} ms.');
  }

  swBfs.stop();
  swTotal.stop();

  print('========================================================');
  print('Import Completed Successfully!');
  print('Total positions traversed: $totalTraversed');
  print('New positions inserted:    $newPositionsCount');
  print('Existing positions updated: $updatedDtwCount');
  print('New edges created:         $newEdgesCount');
  print('Time taken:                ${swTotal.elapsedMilliseconds / 1000} seconds');
  print('========================================================');

  await db.close();
}
