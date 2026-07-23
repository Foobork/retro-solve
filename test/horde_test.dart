import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';

void main() {
  group('Horde Chess Variant Tests', () {
    test('FEN loading and getters for Horde', () {
      final game = HordeChess();
      const fen = 'rnbqkbnr/pppppppp/8/1PP2PP1/PPPPPPPP/PPPPPPPP/PPPPPPPP/PPPPPPPP w kq - 0 1';
      expect(Chess.validateFen(fen)['valid'], isTrue);

      final success = game.load(fen);
      expect(success, isTrue);
      expect(game.isHorde, isTrue);
      expect(game.castling[PlayerColor.white], equals(0));
      expect(game.castling[PlayerColor.black], equals(96)); // kq (32 + 64 = 96)
    });

    test('White pawns on 1st and 2nd rank can double push when clear', () {
      final game = HordeChess();
      
      // Test 1st rank double push
      game.load('8/8/8/8/8/8/8/P7 w - - 0 1'); // White pawn on a1, rest empty
      var moves = game.generateMoves();
      final a1Toa3 = moves.any((m) => m.fromAlgebraic == 'a1' && m.toAlgebraic == 'a3');
      expect(a1Toa3, isTrue, reason: 'Pawn on a1 should be able to move to a3');

      // Test 2nd rank double push
      game.load('8/8/8/8/8/8/P7/8 w - - 0 1'); // White pawn on a2, rest empty
      moves = game.generateMoves();
      final a2Toa4 = moves.any((m) => m.fromAlgebraic == 'a2' && m.toAlgebraic == 'a4');
      expect(a2Toa4, isTrue, reason: 'Pawn on a2 should be able to move to a4');
    });

    test('White is never in check because there is no King', () {
      final game = HordeChess();
      game.reset();
      expect(game.inCheck, isFalse);
      expect(game.inCheckmate, isFalse);
    });

    test('Game over when White has no pieces left', () {
      final game = HordeChess();
      
      // Load position where White only has 1 piece (a pawn)
      game.load('rnbqkbnr/pppppppp/8/8/8/8/8/P7 w kq - 0 1');
      expect(game.gameOver, isFalse);

      // Now load a position where White has no pieces at all
      game.load('rnbqkbnr/pppppppp/8/8/8/8/8/8 w kq - 0 1');
      expect(game.gameOver, isTrue);
    });
  });
}
