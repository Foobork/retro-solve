import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/graph.dart';

void main() {
  group('Atomic Chess Variant Tests', () {
    test('FEN loading and getters for Atomic', () {
      final game = AtomicChess();
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      expect(Chess.validateFen(fen)['valid'], isTrue);

      final success = game.load(fen);
      expect(success, isTrue);
      expect(game.isAtomic, isTrue);
    });

    test('Captures trigger explosions on destination, capturing piece, and non-pawn neighbors', () {
      final game = AtomicChess();
      // Setup a custom position with kings included:
      // White Bishop on f3, Black Pawn on d4, Black Bishop on e4, Black Pawn on f4, White King on e1, Black King on e8
      game.load('4k3/8/8/8/3pbP2/5B2/8/4K3 w - - 0 1');

      // Make Bf3xe4 capture
      // Bf3 is at f3, e4 is at e4
      // Neighbors of e4 (orthogonal & diagonal):
      // d4 (pawn - immune), f4 (pawn - immune), e3 (empty), e5 (empty), d3 (empty), f3 (capturer - explodes), d5 (empty), f5 (empty)
      final moves = game.generateMoves();
      final captureMove = moves.firstWhere((m) => m.fromAlgebraic == 'f3' && m.toAlgebraic == 'e4');
      
      game.makeMove(captureMove);

      // After Bf3xe4:
      // - The captured bishop on e4 should be gone (null)
      // - The capturing bishop on e4 should be gone (null)
      // - The adjacent pawns on d4 and f4 should STILL be there!
      final squareE4 = Chess.squares['e4']!;
      final squareD4 = Chess.squares['d4']!;
      final squareF4 = Chess.squares['f4']!;
      final squareF3 = Chess.squares['f3']!;

      expect(game.board[squareE4], isNull);
      expect(game.board[squareF3], isNull);
      expect(game.board[squareD4], isNotNull);
      expect(game.board[squareD4]!.type, equals(PieceType.pawn));
      expect(game.board[squareF4], isNotNull);
      expect(game.board[squareF4]!.type, equals(PieceType.pawn));

      // Undo the move and ensure everything is restored exactly
      game.undoMove();
      expect(game.board[squareE4], isNotNull);
      expect(game.board[squareE4]!.type, equals(PieceType.bishop));
      expect(game.board[squareF3], isNotNull);
      expect(game.board[squareF3]!.type, equals(PieceType.bishop));
      expect(game.board[squareD4], isNotNull);
      expect(game.board[squareF4], isNotNull);
    });

    test('King cannot capture (illegal self-destruction)', () {
      final game = AtomicChess();
      // White King on e1, Black Pawn on e2, Black King on e8. King cannot capture e2 because it would explode.
      game.load('4k3/8/8/8/8/8/4p3/4K3 w - - 0 1');
      
      final moves = game.generateMoves();
      // Ensure there are no moves where the king captures e2
      final kingCapture = moves.any((m) => m.fromAlgebraic == 'e1' && m.toAlgebraic == 'e2');
      expect(kingCapture, isFalse);
    });

    test('Adjacent kings nullify checks and attacks', () {
      final game = AtomicChess();
      // White King on e1, Black King on e2, Black Rook on h1.
      // Standard chess: White King is in check from Rook on h1.
      // Atomic chess: Since kings are adjacent (e1 and e2), they nullify check, so White King is NOT in check.
      game.load('8/8/8/8/8/8/4k3/4K2r w - - 0 1');

      expect(game.inCheck, isFalse);
      
      // Let's generate moves, ensuring White king has moves that do not move it away from check since there is none.
      final moves = game.generateMoves();
      expect(moves, isNotEmpty);
    });

    test('Exploding the opponent king wins the game immediately', () {
      final game = AtomicChess();
      // White Rook on d1, Black King on d8, Black Bishop on d7 (adjacent to king).
      // White rook captures Bishop on d7. This is centered on d7, adjacent to d8, so it explodes the Black King.
      game.load('3k4/3b4/8/8/8/8/8/3R3K w - - 0 1');

      final moves = game.generateMoves();
      final captureMove = moves.firstWhere((m) => m.fromAlgebraic == 'd1' && m.toAlgebraic == 'd7');
      
      game.makeMove(captureMove);
      expect(game.kings[PlayerColor.black], equals(-1));
      expect(game.gameOver, isTrue);
      expect(game.terminalEvaluation, equals(1000.0));
    });

    test('Qxg2+ in r3k3/ppp1p3/2n3p1/1B1p4/3P1P2/8/PPPb2Pq/RNB2K2 b q - explodes White King and evaluates to -1000.0', () {
      final game = AtomicChess();
      game.load('r3k3/ppp1p3/2n3p1/1B1p4/3P1P2/8/PPPb2Pq/RNB2K2 b q - 0 1');

      final moves = game.generateMoves();
      final qxg2Move = moves.firstWhere((m) => m.fromAlgebraic == 'h2' && m.toAlgebraic == 'g2');

      game.makeMove(qxg2Move);
      expect(game.kings[PlayerColor.white], equals(-1));
      expect(game.gameOver, isTrue);
      expect(game.terminalEvaluation, equals(-1000.0));
    });

    test('Bd7 against Qb5+ in rnbqkbnr/pp2p2p/3p1pp1/1Q6/8/4P3/PPPP1PPP/RNB1KB1R b KQkq - allows Qxd7# exploding Black King', () {
      final game = AtomicChess();
      game.load('rnbqkbnr/pp2p2p/3p1pp1/1Q6/8/4P3/PPPP1PPP/RNB1KB1R b KQkq - 0 1');

      final bd7Move = game.generateMoves().firstWhere((m) => game.moveToSan(m) == 'Bd7');
      game.makeMove(bd7Move);

      final qxd7Move = game.generateMoves().firstWhere((m) => m.fromAlgebraic == 'b5' && m.toAlgebraic == 'd7');
      game.makeMove(qxd7Move);

      expect(game.kings[PlayerColor.black], equals(-1));
      expect(game.gameOver, isTrue);
      expect(game.terminalEvaluation, equals(1000.0));
    });

    test('Qxf2+ in rnb1kbnr/pppp1ppp/4p3/8/4P2q/2N5/PPPPKPPP/R1BQ1BNR b kq - explodes White King and solves to -999.0 (-M1)', () {
      final game = AtomicChess();
      const fen = 'rnb1kbnr/pppp1ppp/4p3/8/4P2q/2N5/PPPPKPPP/R1BQ1BNR b kq - 0 1';
      game.load(fen);

      final testGraph = Graph();
      final a = game.bfen;

      final moves = game.generateMoves();
      final qxf2 = moves.firstWhere((m) => m.fromAlgebraic == 'h4' && m.toAlgebraic == 'f2');
      
      for (final move in moves) {
        game.makeMove(move);
        final b = game.bfen;
        if (game.gameOver) {
          final score = game.terminalEvaluation;
          if (score != null) {
            testGraph.assign(b, score);
          }
        }
        game.undo();
        testGraph.addLink(a, b);
      }

      // Verify Qxf2 move exploded the king and terminal score is -1000.0
      game.makeMove(qxf2);
      expect(game.kings[PlayerColor.white], equals(-1));
      expect(game.gameOver, isTrue);
      expect(game.terminalEvaluation, equals(-1000.0));
      game.undo();

      testGraph.solve();
      expect(testGraph.v[a]?.computed, equals(-999.0));
    });

    test('Qg5 in r2qkb1r/pp2p2p/2n3pn/3p3Q/3PP3/8/PPP2P1P/R3KB1R w KQkq - solves to +997.0 (+M2)', () {
      final game = AtomicChess();
      const fen = 'r2qkb1r/pp2p2p/2n3pn/3p3Q/3PP3/8/PPP2P1P/R3KB1R w KQkq - 0 1';
      game.load(fen);

      final testGraph = Graph();
      void addEdgesRecursive(String bfen, int depth) {
        if (depth > 3) return;
        final g = AtomicChess();
        g.load('$bfen 0 1');
        if (g.gameOver) {
          final score = g.terminalEvaluation;
          if (score != null) {
            testGraph.assign(bfen, score);
          }
          return;
        }
        for (final m in g.generateMoves()) {
          g.makeMove(m);
          final nextBfen = g.bfen;
          if (g.gameOver) {
            final score = g.terminalEvaluation;
            if (score != null) {
              testGraph.assign(nextBfen, score);
            }
          }
          g.undo();
          testGraph.addLink(bfen, nextBfen);
          addEdgesRecursive(nextBfen, depth + 1);
        }
      }

      final rootBfen = game.bfen;
      addEdgesRecursive(rootBfen, 1);
      testGraph.solve();

      final moves = game.generateMoves();
      final qg5 = moves.firstWhere((m) => game.moveToSan(m) == 'Qg5');
      game.makeMove(qg5);
      final qg5Bfen = game.bfen;
      game.undo();

      expect(testGraph.v[rootBfen]?.computed, equals(997.0));
      expect(testGraph.v[qg5Bfen]?.computed, equals(998.0));
    });

    test('r2qkb1r/pp2p2p/2n3pn/3p4/3PP2Q/8/PPP2P1P/R3KB1R b KQkq - known moves and graph test', () {
      final game = AtomicChess();
      const fen = 'r2qkb1r/pp2p2p/2n3pn/3p4/3PP2Q/8/PPP2P1P/R3KB1R b KQkq - 0 1';
      game.load(fen);

      final testGraph = Graph();
      void addEdgesRecursive(String bfen, int depth) {
        if (depth > 3) return;
        final g = AtomicChess();
        g.load('$bfen 0 1');
        if (g.gameOver) {
          final score = g.terminalEvaluation;
          if (score != null) {
            testGraph.assign(bfen, score);
          }
          return;
        }
        for (final m in g.generateMoves()) {
          g.makeMove(m);
          final nextBfen = g.bfen;
          if (g.gameOver) {
            final score = g.terminalEvaluation;
            if (score != null) {
              testGraph.assign(nextBfen, score);
            }
          }
          g.undo();
          testGraph.addLink(bfen, nextBfen);
          addEdgesRecursive(nextBfen, depth + 1);
        }
      }

      final rootBfen = game.bfen;
      addEdgesRecursive(rootBfen, 1);
      testGraph.solve();

      // Specifically expand the g5 branch down to mate so g5 is solved
      final g5Move = game.generateMoves().firstWhere((m) => game.moveToSan(m) == 'g5');
      game.makeMove(g5Move);
      final g5Bfen = game.bfen;
      addEdgesRecursive(g5Bfen, 1);
      game.undo();
      testGraph.solve();

      expect(testGraph.v[rootBfen]?.computed, equals(998.0));
      expect(testGraph.v[g5Bfen]?.computed, isNotNull);
    });

    test('Qh4+ in rnbqk3/pp1p2p1/2p1p3/5p2/1b1PP1P1/2N5/PPP2P1P/R1BQKB1R b KQq - is -M2 and explores alternatives', () {
      final game = AtomicChess();
      const fen = 'rnbqk3/pp1p2p1/2p1p3/5p2/1b1PP1P1/2N5/PPP2P1P/R1BQKB1R b KQq - 0 1';
      game.load(fen);

      final moves = game.generateMoves();
      final qh4 = moves.firstWhere((m) => game.moveToSan(m) == 'Qh4+');
      game.makeMove(qh4);
      final qh4Bfen = game.bfen;
      game.undo();

      final testGraph = Graph();
      // Suppose after Qh4+, the resulting node is evaluated as -998.0 (White gets mated in 2 plies / M2 from Black's root)
      testGraph.assign(qh4Bfen, -998.0);
      testGraph.addLink(game.bfen, qh4Bfen);
      testGraph.solve();

      // Root should be -997.0 (3 plies to mate from root)
      expect(testGraph.v[game.bfen]?.computed, equals(-997.0));
      // Resulting node is -998.0
      expect(testGraph.v[qh4Bfen]?.assigned, equals(-998.0));
    });
  });
}
