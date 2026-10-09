import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/cached_graph.dart';
import 'package:retro_solve/persistence/database_service.dart';

void main() {
  test('navigation sequence 1. Nf3 f6 2. e3 d5 solves promptly without UI delay', () async {
    final dbFile = File('data/Atomic.db');
    if (!dbFile.existsSync()) {
      return; // Skip if database file is not present in local checkout
    }

    sqfliteFfiInit();
    final absPath = dbFile.absolute.path;
    await DatabaseService.instance.init(absPath);
    final graph = CachedGraph(dbService: DatabaseService.instance);

    final game = AtomicChess();
    final moves = ['Nf3', 'f6', 'e3', 'd5'];

    for (final moveSan in moves) {
      game.move(moveSan);
      final currentBfen = game.bfen;

      final childBfens = <String>[];
      for (final m in game.generateMoves()) {
        game.makeMove(m);
        childBfens.add(game.bfen);
        game.undo();
      }

      await graph.prefetchPositions([currentBfen, ...childBfens]);
      for (final b in childBfens) {
        graph.addLink(currentBfen, b);
      }

      final sw = Stopwatch()..start();
      await graph.solveBfenAsync(currentBfen);
      sw.stop();

      // Ensure solveBfenAsync takes well under 100ms per navigated move (was previously > 2000ms on 2... d5)
      expect(sw.elapsedMilliseconds, lessThan(200),
          reason: 'solveBfenAsync took ${sw.elapsedMilliseconds}ms on $moveSan, which exceeds snappiness threshold');
    }

    await DatabaseService.instance.close();
  });
}
