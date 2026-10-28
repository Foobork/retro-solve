// ignore_for_file: avoid_print

import 'dart:io';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/position_eval.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Future<void> main(List<String> args) async {
  final dbPath = args.isNotEmpty ? args[0] : 'data/Antichess.db';
  final dbFile = File(dbPath).absolute;
  if (!dbFile.existsSync()) {
    print('Database not found: ${dbFile.path}');
    exit(1);
  }

  final moves = [
    'e3', 'c5', 'Bb5', 'Qc7', 'Bxd7', 'Bxd7', 'Qf3', 'Qxh2', 'Rxh2', 'h6',
    'Rxh6', 'Nxh6', 'Qxb7', 'Bh3', 'Nxh3', 'g5', 'Nxg5', 'Ng8', 'Qxe7', 'Nxe7',
    'Nxf7', 'Kxf7', 'b4', 'cxb4', 'Ba3', 'bxa3', 'Nxa3', 'Bh6', 'Nc4', 'Bxe3',
    'dxe3', 'Na6', 'f4', 'Ng8', 'Nb2', 'Rh6', 'g3', 'Kg7', 'Na4', 'Rb6',
    'Nxb6', 'axb6', 'Kd2', 'Rb8', 'Rd1', 'Kf8', 'g4', 'Ne7', 'f5', 'Nxf5',
    'gxf5', 'Ke7', 'e4', 'Nc7', 'Rc1', 'Kd8', 'f6', 'Ke8', 'Ke3', 'Kd7',
    'Re1', 'Kc6', 'Re2', 'Kd7', 'Kf4', 'Rc8', 'f7', 'Re8', 'fxe8=R', 'Kxe8',
    'e5', 'Kd7', 'Re1', 'Kd8', 'Ke3', 'Na6', 'Ke4', 'Ke8', 'e6', 'Kd8',
    'Ke5', 'Kc8', 'e7', 'Kb7', 'Kf5', 'Ka8', 'Ke6', 'Kb8', 'a3', 'Kb7',
    'Re4', 'Kb8', 'c3', 'Kb7', 'Rb4', 'Nxb4', 'cxb4', 'Kb8', 'b5', 'Kb7',
    'e8=K', 'Kb8', 'Kd5', 'Kb7', 'Ke7', 'Ka6', 'bxa6', 'b5', 'a4', 'bxa4',
    'Kee6', 'a3', 'Kc4', 'a2', 'Ked5', 'a1=K', 'a7', 'Kb2', 'Kc3', 'Kxc3',
    'Kd4', 'Kxd4', 'a8=R', 'Ke5', 'Rc8', 'Ke4', 'Rc6', 'Kf3', 'Rd6', 'Kf4',
    'Rd8', 'Kf5', 'Rd3', 'Kf6', 'Rd4', 'Kg7', 'Rd5', 'Kf7', 'Rh5', 'Ke7',
    'Rc5', 'Kf7', 'Rd5', 'Kg8', 'Rd6', 'Kf8', 'Rh6', 'Ke8', 'Rc6', 'Kf8',
    'Rd6', 'Kg8', 'Re6', 'Kh8', 'Rf6', 'Kg8', 'Rf8', 'Kxf8'
  ];

  print('========================================================');
  print('Antichess 79-Move Line Align & Repair');
  print('Database: ${dbFile.path}');
  print('Moves: ${moves.length} plies (79 full moves)');
  print('========================================================');

  final totalPlies = moves.length; // 158

  // 1. Play moves and record each position (BFEN and remaining plies)
  final game = AntichessChess();
  final positions = <({String bfen, int dtw, bool isWhite, String? moveMade})>[];

  // Starting position (Ply 0, before 1. e3)
  positions.add((
    bfen: game.bfen,
    dtw: totalPlies,
    isWhite: true,
    moveMade: null,
  ));

  for (int i = 0; i < moves.length; i++) {
    final mStr = moves[i];
    game.move(mStr);
    final remainingPlies = totalPlies - (i + 1);
    final isWhite = game.turn == PlayerColor.white;
    positions.add((
      bfen: game.bfen,
      dtw: remainingPlies,
      isWhite: isWhite,
      moveMade: mStr,
    ));
  }

  print('Total positions in line: ${positions.length}');
  print('Initial position: ${positions.first.bfen} -> DTW=${positions.first.dtw}');
  print('Terminal position: ${positions.last.bfen} -> DTW=${positions.last.dtw}');

  sqfliteFfiInit();
  final db = await databaseFactoryFfi.openDatabase(dbFile.path);
  await db.execute('PRAGMA journal_mode = WAL;');
  await db.execute('PRAGMA synchronous = NORMAL;');

  // 2. Insert or update positions in DB
  final bfenToId = <String, int>{};
  int updatedCount = 0;
  int insertedCount = 0;

  await db.transaction((txn) async {
    for (final p in positions) {
      final existing = await txn.rawQuery('SELECT id, assigned_dtw, computed_dtw FROM positions WHERE bfen = ?;', [p.bfen]);
      if (existing.isNotEmpty) {
        final id = existing.first['id'] as int;
        bfenToId[p.bfen] = id;
        await txn.rawUpdate('''
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
        ''', [p.dtw, p.dtw, id]);
        updatedCount++;
      } else {
        final newId = await txn.rawInsert('''
          INSERT INTO positions (
            bfen, assigned_result, assigned_dtw, assigned_cp,
            computed_result, computed_dtw, computed_cp,
            proof_status, pn, dn
          ) VALUES (?, 1, ?, NULL, 1, ?, NULL, 1, 0, 1000000000);
        ''', [p.bfen, p.dtw, p.dtw]);
        bfenToId[p.bfen] = newId;
        insertedCount++;
      }
    }

    // 3. Ensure edges exist along the trajectory and set proven_move_id for White positions
    for (int i = 0; i < positions.length - 1; i++) {
      final srcBfen = positions[i].bfen;
      final tgtBfen = positions[i + 1].bfen;
      final srcId = bfenToId[srcBfen]!;
      final tgtId = bfenToId[tgtBfen]!;

      await txn.rawInsert(
        'INSERT OR IGNORE INTO edges (source_id, target_id) VALUES (?, ?);',
        [srcId, tgtId],
      );

      // If White to move, set proven_move_id to the winning target node
      if (positions[i].isWhite) {
        await txn.rawUpdate(
          'UPDATE positions SET proven_move_id = ? WHERE id = ?;',
          [tgtId, srcId],
        );
      }
    }
  });

  print('Updated $updatedCount positions and inserted $insertedCount positions.');

  // 4. Verification of key checkpoints
  print('\nVerification Checkpoints:');
  final checkpoints = [
    (0, '1. e3 (before)'),
    (1, '1... c5 (before)'),
    (2, '2. Bb5 (before)'),
    (96, '49. cxb4 (before)'),
    (97, '49... Kb8 (before)'),
    (98, '50. b5 (before)'),
    (99, '50... Kb7 (before)'),
    (156, '79. Rf8 (before)'),
    (157, '79... Kxf8 (before)'),
    (158, 'Game Over (after 79... Kxf8)'),
  ];

  for (final cp in checkpoints) {
    final pos = positions[cp.$1];
    final rows = await db.rawQuery('SELECT id, bfen, assigned_dtw, computed_dtw FROM positions WHERE bfen = ?;', [pos.bfen]);
    final r = rows.first;
    final dtw = r['computed_dtw'] as int;
    final posEval = PositionEval(result: GameResult.whiteWins, dtw: dtw);
    print('  ${cp.$2}: DTW=$dtw | Pos: ${posEval.format(isMove: false)} | Move: ${posEval.format(isMove: true)}');
  }

  await db.close();
  print('\nRepair completed successfully!');
}
