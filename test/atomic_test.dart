import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';

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
    });
  });
}
