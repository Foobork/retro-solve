// ignore_for_file: avoid_print

import 'dart:io';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/cached_graph.dart';
import 'package:retro_solve/graph/position_eval.dart';
import 'package:retro_solve/graph/watkins_proof_index.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:retro_solve/persistence/db_init.dart';
import 'antichess_tb_ffi.dart';

int countPieces(String bfen) {
  final boardStr = bfen.split(' ')[0];
  int count = 0;
  for (int i = 0; i < boardStr.length; i++) {
    final c = boardStr.codeUnitAt(i);
    if ((c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a)) {
      count++;
    }
  }
  return count;
}

Future<void> main(List<String> args) async {
  final movesArg = args.isNotEmpty ? args[0] : 'e3,c5';
  final dbPathArg = args.length > 1 ? args[1] : 'data/Antichess.db';
  final maxRounds = args.length > 2 ? int.parse(args[2]) : 50;

  final dbPath = resolvePlatformDbPath(dbPathArg);
  print('========================================================');
  print('Principal Variation Optimizer for Antichess');
  print('Root line:     $movesArg');
  print('Database:      $dbPath');
  print('Max rounds:    $maxRounds');
  print('========================================================');

  WatkinsProofIndexManager.instance.ensureLoaded();
  print('Proof indices active: ${WatkinsProofIndexManager.instance.hasIndices}');

  AntichessTbProber? prober;
  final tbDll = File('data/tablebases/antichess/antichess_tb_api.dll');
  if (tbDll.existsSync()) {
    try {
      prober = AntichessTbProber();
      print('Antichess 2-4 piece tablebase prober loaded.');
    } catch (e) {
      print('Tablebase prober load failed: $e');
    }
  }

  await DatabaseService.instance.init(dbPath);
  final graph = CachedGraph();

  // 1. Play prolog moves
  final game = AntichessChess();
  final prologMoves = movesArg.split(',').map((s) => s.trim()).toList();
  for (final mStr in prologMoves) {
    final mObj = game.generateMoves().firstWhere(
      (m) => game.moveToSan(m) == mStr,
      orElse: () => throw ArgumentError('Illegal move "$mStr" in prolog'),
    );
    game.makeMove(mObj);
  }

  final rootBfen = game.bfen;
  print('Root BFEN: $rootBfen');
  final rootVertex = await graph.loadVertex(rootBfen);
  print('Root initial eval: ${rootVertex?.effectiveEval?.format()} (DTW: ${rootVertex?.effectiveEval?.dtw})');

  final swTotal = Stopwatch()..start();
  int? prevRootDtw = rootVertex?.effectiveEval?.dtw;
  List<String> prevPvSan = [];
  int totalIndexHits = 0;
  int totalTbHits = 0;

  PositionEval? probeChild(String childBfen, AntichessChess childGame) {
    if (childGame.gameOver) {
      final score = childGame.terminalEvaluation;
      if (score != null) {
        return PositionEval.fromLegacyScore(score);
      }
    }

    if (prober != null && countPieces(childBfen) <= 4) {
      final tbRes = prober.probeBfen(childBfen);
      if (tbRes != null && tbRes.dtw != null) {
        totalTbHits++;
        final gRes = tbRes.whitePerspectiveResult > 0
            ? GameResult.whiteWins
            : (tbRes.whitePerspectiveResult < 0
                ? GameResult.blackWins
                : GameResult.draw);
        return PositionEval(result: gRes, dtw: tbRes.dtw);
      }
    }

    final entry = WatkinsProofIndexManager.instance.lookupBfen(childBfen);
    if (entry != null) {
      totalIndexHits++;
      return PositionEval(result: GameResult.whiteWins, dtw: entry.dtw);
    }

    return null;
  }

  for (int round = 1; round <= maxRounds; round++) {
    print('\n--- Round $round ---');
    final roundSw = Stopwatch()..start();

    // Traverse along current principal variation
    final pvBfens = <String>[rootBfen];
    final pvSans = <String>[];
    final trajGame = game.copy();

    while (true) {
      final currBfen = trajGame.bfen;
      if (trajGame.gameOver) break;

      final legalMoves = trajGame.generateMoves();
      if (legalMoves.isEmpty) break;

      final childBfens = <String>[];
      final childMoves = <Move>[];
      for (final m in legalMoves) {
        trajGame.makeMove(m);
        childBfens.add(trajGame.bfen);
        childMoves.add(m);
        trajGame.undo();
      }

      await graph.prefetchPositions(childBfens);
      for (final c in childBfens) {
        graph.addLink(currBfen, c);
      }

      // Check for unproven children against indices & tablebases
      for (int i = 0; i < childBfens.length; i++) {
        final cBfen = childBfens[i];
        final cv = graph.v[cBfen];
        if (cv?.effectiveEval == null) {
          final tempGame = trajGame.copy()..makeMove(childMoves[i]);
          final probed = probeChild(cBfen, tempGame);
          if (probed != null) {
            graph.assign(cBfen, probed);
            await DatabaseService.instance.upsertNode(cBfen, probed, probed);
          }
        }
      }

      // Solve currBfen locally
      await graph.solveBfenAsync(currBfen);

      final currV = graph.v[currBfen];
      final isWhite = currV?.whiteToMove ?? true;

      // Find best move along current policy
      int? bestDtw;
      String? bestChildBfen;
      Move? bestMove;

      for (int i = 0; i < childBfens.length; i++) {
        final cBfen = childBfens[i];
        final cv = graph.v[cBfen];
        final cEval = cv?.effectiveEval;
        if (cEval == null) continue;

        if (cEval.result == GameResult.whiteWins && cEval.dtw != null) {
          final d = cEval.dtw!;
          if (isWhite) {
            // White wants MIN dtw
            if (bestDtw == null || d < bestDtw) {
              bestDtw = d;
              bestChildBfen = cBfen;
              bestMove = childMoves[i];
            }
          } else {
            // Black wants MAX dtw
            if (bestDtw == null || d > bestDtw) {
              bestDtw = d;
              bestChildBfen = cBfen;
              bestMove = childMoves[i];
            }
          }
        }
      }

      if (bestMove == null || bestChildBfen == null) {
        break;
      }

      pvSans.add(trajGame.moveToSan(bestMove));
      trajGame.makeMove(bestMove);
      pvBfens.add(bestChildBfen);

      // Truncate if reached tablebase / end
      if (trajGame.gameOver || (prober != null && countPieces(bestChildBfen) <= 4)) {
        break;
      }
      if (pvBfens.length > 200) {
        break;
      }
    }

    // Backsolve up the path from leaf to root
    for (int i = pvBfens.length - 1; i >= 0; i--) {
      await graph.solveBfenAsync(pvBfens[i]);
    }

    final currRootDtw = graph.v[rootBfen]?.effectiveEval?.dtw;
    final currRootEvalStr = graph.v[rootBfen]?.effectiveEval?.format();
    final pvStr = pvSans.take(12).join(' ');

    print(
      'Round $round ($currRootEvalStr, DTW: $currRootDtw, ${roundSw.elapsedMilliseconds}ms): $pvStr${pvSans.length > 12 ? "..." : ""}',
    );

    // Check convergence
    if (currRootDtw == prevRootDtw && _listEquals(pvSans, prevPvSan)) {
      print('\n*** CONVERGED! Principal variation is fully stabilized. ***');
      break;
    }

    prevRootDtw = currRootDtw;
    prevPvSan = List.from(pvSans);
  }

  swTotal.stop();
  final finalEval = graph.v[rootBfen]?.effectiveEval;
  print('\n========================================================');
  print('Optimization Complete in ${swTotal.elapsedMilliseconds}ms');
  print('Initial Root Eval: ${rootVertex?.effectiveEval?.format()} (DTW: ${rootVertex?.effectiveEval?.dtw})');
  print('Final Root Eval:   ${finalEval?.format()} (DTW: ${finalEval?.dtw})');
  print('Plies saved:       ${(rootVertex?.effectiveEval?.dtw ?? 0) - (finalEval?.dtw ?? 0)}');
  print('Total Index hits:  $totalIndexHits');
  print('Total TB hits:     $totalTbHits');
  print('========================================================');

  prober?.dispose();
  await DatabaseService.instance.close();
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (int i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
