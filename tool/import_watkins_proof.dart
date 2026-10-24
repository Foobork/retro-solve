// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';
import 'package:retro_solve/chess/chess.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'antichess_tb_ffi.dart';

String decodeWatkinsMove(int mv) {
  if (mv == 0xfedc || mv == 0x0edc) return 'NULL';
  if ((mv >> 12) > 8 || (mv >> 12) == 7) {
    mv ^= 0xf000;
  }
  final fr = (mv >> 6) & 0x3f;
  final to = mv & 0x3f;
  final promIdx = (mv >> 12) & 0x7;
  const promChars = '01nbrqk7';

  final fromFile = String.fromCharCode('a'.codeUnitAt(0) + (fr & 7));
  final fromRank = (1 + (fr >> 3)).toString();
  final toFile = String.fromCharCode('a'.codeUnitAt(0) + (to & 7));
  final toRank = (1 + (to >> 3)).toString();

  var res = '$fromFile$fromRank$toFile$toRank';
  if ((mv & (7 << 12)) != 0 && promIdx < promChars.length) {
    res += promChars[promIdx];
  }
  return res;
}

int watkinsSquareTo0x88(int sq64) {
  final file = sq64 & 7;
  final rank = sq64 >> 3; // 0 = rank 1, 7 = rank 8
  return (7 - rank) * 16 + file;
}

PieceType? watkinsPromToPieceType(int mv) {
  if ((mv >> 12) > 8 || (mv >> 12) == 7) {
    mv ^= 0xf000;
  }
  final promIdx = (mv >> 12) & 0x7;
  switch (promIdx) {
    case 2:
      return PieceType.knight;
    case 3:
      return PieceType.bishop;
    case 4:
      return PieceType.rook;
    case 5:
      return PieceType.queen;
    case 6:
      return PieceType.king;
    default:
      return null;
  }
}

Move findFastMove(AntichessChess game, int rawMv) {
  var mv = rawMv;
  if ((mv >> 12) > 8 || (mv >> 12) == 7) {
    mv ^= 0xf000;
  }
  final from0x88 = watkinsSquareTo0x88((mv >> 6) & 0x3f);
  final to0x88 = watkinsSquareTo0x88(mv & 0x3f);
  final prom = watkinsPromToPieceType(mv);

  final moves = game.generateMoves({'square': Chess.algebraic(from0x88)});
  for (int i = 0; i < moves.length; i++) {
    final m = moves[i];
    if (m.from == from0x88 && m.to == to0x88 && m.promotion == prom) {
      return m;
    }
  }
  // Fallback to full legal move generation
  final allMoves = game.generateMoves();
  for (int i = 0; i < allMoves.length; i++) {
    final m = allMoves[i];
    if (m.from == from0x88 && m.to == to0x88 && m.promotion == prom) {
      return m;
    }
  }
  throw StateError(
    'Illegal Watkins move ${decodeWatkinsMove(rawMv)} at ${game.bfen}',
  );
}

class _Frame {
  final int u;
  final bool returning;
  final String parentBfen;
  const _Frame(this.u, this.returning, this.parentBfen);
}

Future<void> main(List<String> args) async {
  final proofPath = args.isNotEmpty ? args[0] : 'easy12.rev.proof';
  final dbPath = args.length > 1 ? args[1] : 'data/Antichess.db';
  final dryRun = args.contains('--dry-run');

  final proofFile = File(proofPath);
  if (!proofFile.existsSync()) {
    print('Proof file not found: $proofPath');
    exit(1);
  }

  final sw = Stopwatch()..start();
  final bytes = proofFile.readAsBytesSync();
  final bd = ByteData.sublistView(bytes);

  final rawHeader = bd.getUint32(0, Endian.little);
  final prologLen = bd.getUint16(4, Endian.little);
  final nodeCount = rawHeader & 0x3fffffff;
  final headerBytes = 6 + 2 * prologLen;

  print('====================================================');
  print('Parsing Watkins Proof: $proofPath');
  print('Node count (including root): $nodeCount, prologLen: $prologLen');

  final game = AntichessChess();
  final startBfen = game.bfen;

  final uniqueBfens = <String>{startBfen};
  final leafBfens = <String>{};
  final gameOverLeafBfens = <String>{};
  final edges = <String, Set<String>>{};
  final provenChildByWhiteBfen = <String, String>{};

  void addEdge(String from, String to) {
    (edges[from] ??= <String>{}).add(to);
  }

  // Apply prolog moves if any
  var currParentBfen = startBfen;
  for (int i = 0; i < prologLen; i++) {
    final pMv = bd.getUint16(6 + i * 2, Endian.little);
    final moveObj = findFastMove(game, pMv);
    final beforeBfen = game.bfen;
    game.makeMove(moveObj);
    final afterBfen = game.bfen;
    uniqueBfens.add(afterBfen);
    addEdge(beforeBfen, afterBfen);
    if (beforeBfen.contains(' w ')) {
      provenChildByWhiteBfen[beforeBfen] = afterBfen;
    }
    currParentBfen = afterBfen;
  }

  final nodeBfenByIndex = List<String?>.filled(nodeCount, null);
  final stack = <_Frame>[_Frame(1, false, currParentBfen)];

  int visited = 0;
  int transpositionHits = 0;

  while (stack.isNotEmpty) {
    final frame = stack.removeLast();
    if (frame.returning) {
      game.undoMove();
      continue;
    }

    final u = frame.u;
    final offset = headerBytes + (u - 1) * 6;
    final data = bd.getUint32(offset, Endian.little);
    final rawMv = bd.getUint16(offset + 4, Endian.little);
    final w = data >> 30;
    final d = data & 0x3fffffff;

    // Push next sibling onto stack first so it executes after this node's subtree returns
    if ((w == 0 || w == 1) && d != 0) {
      stack.add(_Frame(d, false, frame.parentBfen));
    } else if (w == 3) {
      stack.add(_Frame(u + 1, false, frame.parentBfen));
    }

    final moveObj = findFastMove(game, rawMv);
    game.makeMove(moveObj);
    visited++;

    final bfen = game.bfen;
    nodeBfenByIndex[u] = bfen;
    uniqueBfens.add(bfen);
    addEdge(frame.parentBfen, bfen);

    if (frame.parentBfen.contains(' w ')) {
      provenChildByWhiteBfen[frame.parentBfen] = bfen;
    }

    if (w == 2 || w == 3) {
      final targetBfen = nodeBfenByIndex[d];
      if (targetBfen == bfen) {
        transpositionHits++;
      } else {
        throw StateError(
          'Transposition mismatch at u=$u -> d=$d: $bfen != $targetBfen',
        );
      }
    }

    if (w == 0) {
      leafBfens.add(bfen);
      if (game.gameOver) {
        gameOverLeafBfens.add(bfen);
      }
    }

    if (w == 1) {
      stack.add(_Frame(u, true, frame.parentBfen));
      stack.add(_Frame(u + 1, false, bfen));
    } else {
      game.undoMove();
    }
  }

  int totalEdges = 0;
  for (final targets in edges.values) {
    totalEdges += targets.length;
  }

  print('DFS traversal complete in ${sw.elapsedMilliseconds}ms:');
  print('  Nodes visited:          $visited / ${nodeCount - 1}');
  print('  Unique BFEN positions:  ${uniqueBfens.length}');
  print('  Unique proof edges:     $totalEdges');
  print('  Transposition links:    $transpositionHits');
  print('  Leaf BFENs (w=0):       ${leafBfens.length} (${gameOverLeafBfens.length} immediate game-over)');
  print('  White OR-nodes proven:  ${provenChildByWhiteBfen.length}');

  // Probe 2-4 piece tablebase leaves if antichess_tb_api.dll is available
  final tbLeafDtw = <String, int>{};
  final nonGameOverLeaves = leafBfens.difference(gameOverLeafBfens);
  if (nonGameOverLeaves.isNotEmpty &&
      File('data/tablebases/antichess/antichess_tb_api.dll').existsSync()) {
    print(
      'Probing ${nonGameOverLeaves.length} non-game-over leaves with AntichessTbProber...',
    );
    final prober = AntichessTbProber();
    for (final bfen in nonGameOverLeaves) {
      final res = prober.probeBfen(bfen);
      if (res != null && res.dtw != null) {
        tbLeafDtw[bfen] = res.dtw!;
      }
    }
    prober.dispose();
    print(
      '  Probed exact DTW for ${tbLeafDtw.length} / ${nonGameOverLeaves.length} tablebase leaves.',
    );
  }

  if (dryRun) {
    print('Dry run complete.');
    return;
  }

  sqfliteFfiInit();
  final dbFile = File(dbPath).absolute;
  print('Opening SQLite database: ${dbFile.path}');
  final db = await databaseFactoryFfi.openDatabase(dbFile.path);

  await db.execute('PRAGMA journal_mode = WAL;');
  await db.execute('PRAGMA synchronous = NORMAL;');

  // Ensure v6 columns exist
  final posInfo = await db.rawQuery("PRAGMA table_info('positions');");
  final posCols = posInfo.map((r) => (r['name'] as String).toLowerCase()).toSet();
  if (!posCols.contains('proof_status')) {
    await db.execute('ALTER TABLE positions ADD COLUMN proof_status INTEGER DEFAULT 0;');
  }
  if (!posCols.contains('pn')) {
    await db.execute('ALTER TABLE positions ADD COLUMN pn INTEGER DEFAULT 1;');
  }
  if (!posCols.contains('dn')) {
    await db.execute('ALTER TABLE positions ADD COLUMN dn INTEGER DEFAULT 1;');
  }
  if (!posCols.contains('proven_move_id')) {
    await db.execute('ALTER TABLE positions ADD COLUMN proven_move_id INTEGER;');
  }

  // 1. Load existing bfen -> id mapping
  print('Loading existing position IDs from database...');
  final bfenToId = <String, int>{};
  int lastId = 0;
  const readChunk = 200000;
  while (true) {
    final rows = await db.rawQuery(
      'SELECT id, bfen FROM positions WHERE id > ? ORDER BY id LIMIT ?;',
      [lastId, readChunk],
    );
    if (rows.isEmpty) break;
    for (final row in rows) {
      final id = row['id'] as int;
      final bfen = row['bfen'] as String;
      bfenToId[bfen] = id;
      lastId = id;
    }
    if (rows.length < readChunk) break;
  }
  print('Existing positions in DB: ${bfenToId.length}');

  // Don't overwrite the initial starting position or 1. e3 root (since 8 of 20 Black replies are in other files)
  final e3Bfen = nodeBfenByIndex[1]!;
  final provenBfens = Set<String>.from(uniqueBfens)
    ..remove(startBfen)
    ..remove(e3Bfen);

  // 2. Insert new positions and update existing proven positions in batches
  final newBfens = <String>[];
  final existingProvenBfens = <String>[];
  for (final bfen in provenBfens) {
    if (bfenToId.containsKey(bfen)) {
      existingProvenBfens.add(bfen);
    } else {
      newBfens.add(bfen);
    }
  }
  for (final rootBfen in [startBfen, e3Bfen]) {
    if (!bfenToId.containsKey(rootBfen)) {
      await db.rawInsert('INSERT OR IGNORE INTO positions (bfen) VALUES (?);', [rootBfen]);
      final r = await db.rawQuery('SELECT id FROM positions WHERE bfen = ?;', [rootBfen]);
      bfenToId[rootBfen] = r.first['id'] as int;
    }
  }

  print('New proven positions to insert: ${newBfens.length}');
  print('Existing positions to mark proven (+Mate): ${existingProvenBfens.length}');

  const batchSize = 10000;
  for (int i = 0; i < newBfens.length; i += batchSize) {
    final end = (i + batchSize < newBfens.length) ? i + batchSize : newBfens.length;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (int j = i; j < end; j++) {
        final bfen = newBfens[j];
        final isLeaf = leafBfens.contains(bfen);
        final isGameOver = gameOverLeafBfens.contains(bfen);
        final aRes = isLeaf ? 1 : null;
        final aDtw = isGameOver ? 0 : tbLeafDtw[bfen];
        final cDtw = isGameOver ? 0 : tbLeafDtw[bfen];
        batch.rawInsert(
          '''
          INSERT INTO positions (
            bfen, assigned_result, assigned_dtw, assigned_cp,
            computed_result, computed_dtw, computed_cp,
            proof_status, pn, dn
          ) VALUES (?, ?, ?, NULL, 1, ?, NULL, 1, 0, 1000000000);
          ''',
          [bfen, aRes, aDtw, cDtw],
        );
      }
      await batch.commit(noResult: true);
    });
    if ((i ~/ batchSize) % 10 == 0 || end == newBfens.length) {
      print('  Inserted $end / ${newBfens.length} positions...');
    }
  }

  print('Updating ${existingProvenBfens.length} existing proven positions...');
  for (int i = 0; i < existingProvenBfens.length; i += batchSize) {
    final end = (i + batchSize < existingProvenBfens.length)
        ? i + batchSize
        : existingProvenBfens.length;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (int j = i; j < end; j++) {
        final bfen = existingProvenBfens[j];
        final id = bfenToId[bfen]!;
        final isLeaf = leafBfens.contains(bfen);
        final isGameOver = gameOverLeafBfens.contains(bfen);
        final aRes = isLeaf ? 1 : null;
        final aDtw = isGameOver ? 0 : tbLeafDtw[bfen];
        final cDtw = isGameOver ? 0 : tbLeafDtw[bfen];
        batch.rawUpdate(
          '''
          UPDATE positions
          SET assigned_result = ?,
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
          [aRes, aDtw, cDtw, id],
        );
      }
      await batch.commit(noResult: true);
    });
    if ((i ~/ batchSize) % 10 == 0 || end == existingProvenBfens.length) {
      print('  Updated $end / ${existingProvenBfens.length} positions...');
    }
  }

  // Reload newly inserted IDs
  print('Fetching new position IDs...');
  while (true) {
    final rows = await db.rawQuery(
      'SELECT id, bfen FROM positions WHERE id > ? ORDER BY id LIMIT ?;',
      [lastId, readChunk],
    );
    if (rows.isEmpty) break;
    for (final row in rows) {
      final id = row['id'] as int;
      final bfen = row['bfen'] as String;
      bfenToId[bfen] = id;
      lastId = id;
    }
    if (rows.length < readChunk) break;
  }

  // 3. Update proven_move_id for White OR-nodes
  print('Updating proven_move_id on ${provenChildByWhiteBfen.length} White OR-nodes...');
  final whiteEntries = provenChildByWhiteBfen.entries.toList();
  for (int i = 0; i < whiteEntries.length; i += batchSize) {
    final end = (i + batchSize < whiteEntries.length) ? i + batchSize : whiteEntries.length;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (int j = i; j < end; j++) {
        final entry = whiteEntries[j];
        final sourceId = bfenToId[entry.key];
        final targetId = bfenToId[entry.value];
        if (sourceId != null && targetId != null) {
          batch.rawUpdate(
            'UPDATE positions SET proven_move_id = ? WHERE id = ?;',
            [targetId, sourceId],
          );
        }
      }
      await batch.commit(noResult: true);
    });
  }

  // 4. Insert all proof edges
  print('Inserting $totalEdges proof edges...');
  final edgePairs = <(int, int)>[];
  for (final entry in edges.entries) {
    final sourceId = bfenToId[entry.key]!;
    for (final targetBfen in entry.value) {
      final targetId = bfenToId[targetBfen]!;
      edgePairs.add((sourceId, targetId));
    }
  }

  for (int i = 0; i < edgePairs.length; i += batchSize) {
    final end = (i + batchSize < edgePairs.length) ? i + batchSize : edgePairs.length;
    await db.transaction((txn) async {
      final batch = txn.batch();
      for (int j = i; j < end; j++) {
        final pair = edgePairs[j];
        batch.rawInsert(
          'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);',
          [pair.$1, pair.$2],
        );
      }
      await batch.commit(noResult: true);
    });
    if ((i ~/ batchSize) % 10 == 0 || end == edgePairs.length) {
      print('  Inserted $end / ${edgePairs.length} edges...');
    }
  }

  await db.close();
  print('Import completed in ${sw.elapsedMilliseconds}ms!');
}
