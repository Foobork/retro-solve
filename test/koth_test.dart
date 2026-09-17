import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/graph.dart';

void main() {
  group('King of the Hill (KOTH) Tests', () {
    test('Kxe5 reaches the hill and evaluates to Black win (-1000.0, -M1)', () {
      final game = KothChess();
      const rootBfen = 'rnb2bnr/ppp3pp/4k3/4Pp2/2B1p3/5P2/PPPK2PP/RNB3NR b - -';
      game.load('$rootBfen 0 1');

      expect(game.gameOver, isFalse);
      expect(game.turn, equals(black));

      final moves = game.generateMoves();
      final kxe5Move = moves.firstWhere((m) => game.moveToSan(m) == 'Kxe5');

      game.makeMove(kxe5Move);
      expect(game.gameOver, isTrue);
      expect(game.isKothGameOver, isTrue);
      expect(game.inDraw, isFalse);
      expect(game.inStalemate, isFalse);
      expect(game.inCheckmate, isFalse);
      expect(game.terminalEvaluation, equals(-1000.0));
      game.undo();
    });

    test('Graph correctly solves root to -M1 when Kxe5 reaches the hill', () {
      final localGraph = Graph();
      final game = KothChess();
      const rootBfen = 'rnb2bnr/ppp3pp/4k3/4Pp2/2B1p3/5P2/PPPK2PP/RNB3NR b - -';
      game.load('$rootBfen 0 1');

      final a = game.bfen;
      final moves = game.generateMoves();
      for (var move in moves) {
        game.makeMove(move);
        final b = game.bfen;
        if (game.gameOver) {
          final score = game.terminalEvaluation;
          if (score != null) {
            localGraph.assign(b, score);
          }
        }
        game.undo();
        localGraph.addLink(a, b);
      }

      localGraph.solve();

      final rootVertex = localGraph.v[a];
      expect(rootVertex, isNotNull);
      // Black to move has a winning move Kxe5 reaching the hill
      expect(rootVertex!.computed, isNotNull);
      expect(rootVertex.computed!.result, equals(GameResult.blackWins));
      expect(rootVertex.computed!.dtw, equals(1)); // -M1 (1 ply to hill win)
      expect(rootVertex.computedScore, equals(-999.0));

      // Check the Kxe5 target vertex
      const targetBfen = 'rnb2bnr/ppp3pp/8/4kp2/2B1p3/5P2/PPPK2PP/RNB3NR w - -';
      final targetVertex = localGraph.v[targetBfen];
      expect(targetVertex, isNotNull);
      expect(targetVertex!.effectiveEval?.result, equals(GameResult.blackWins));
      expect(targetVertex.effectiveEval?.dtw, equals(0)); // -M0 (hill reached)
      expect(targetVertex.assignedScore, equals(-1000.0));
    });

    test('White king reaching hill evaluates to +1000.0 and not draw', () {
      final game = KothChess();
      // White king on d4
      const whiteHillBfen = 'rnbqkbnr/pppppppp/8/8/3K4/8/PPPPPPPP/RNBQ1BNR b KQkq -';
      game.load('$whiteHillBfen 0 1');

      expect(game.gameOver, isTrue);
      expect(game.isKothGameOver, isTrue);
      expect(game.inDraw, isFalse);
      expect(game.inStalemate, isFalse);
      expect(game.terminalEvaluation, equals(1000.0));
    });
  });
}
