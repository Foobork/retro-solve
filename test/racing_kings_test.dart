import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';

void main() {
  group('Racing Kings Chess Variant Tests', () {
    test('FEN loading and getters for Racing Kings', () {
      final game = RacingKingsChess();
      const fen = '8/8/8/8/8/8/krbnNBRK/qrbnNBRQ w - - 0 1';
      expect(Chess.validateFen(fen)['valid'], isTrue);

      final success = game.load(fen);
      expect(success, isTrue);
      expect(game.isRacingKings, isTrue);
      expect(game.castling[PlayerColor.white], equals(0));
      expect(game.castling[PlayerColor.black], equals(0));
    });

    test('Giving check is illegal in Racing Kings', () {
      final game = RacingKingsChess();
      // Setup position: White Rook on b3, Black King on a2, White King on h1
      // FEN: 7K/8/8/8/8/1R6/k7/8 w - - 0 1
      game.load('7K/8/8/8/8/1R6/k7/8 w - - 0 1');

      final moves = game.generateMoves();
      
      // Moving White Rook to a3 (Rb3-a3) would place the Black King on a2 in check.
      // Thus, Rb3-a3 must be illegal and not present in legal moves.
      final checkMove = moves.any((m) => m.fromAlgebraic == 'b3' && m.toAlgebraic == 'a3');
      expect(checkMove, isFalse, reason: 'Rb3-a3 gives check, so it must be illegal');

      // Moving White Rook to b4 (Rb3-b4) does not check the Black King on a2.
      // Thus, Rb3-b4 must be legal and present in legal moves.
      final safeMove = moves.any((m) => m.fromAlgebraic == 'b3' && m.toAlgebraic == 'b4');
      expect(safeMove, isTrue, reason: 'Rb3-b4 does not give check, so it must be legal');
    });

    test('Racing win and draw conditions', () {
      final game = RacingKingsChess();
      
      // White King on a8 (8th rank), Black King on a1, White to move.
      // Game is over, White wins.
      game.load('K7/8/8/8/8/8/8/k7 w - - 0 1');
      expect(game.gameOver, isTrue);
      expect(game.inDraw, isFalse);

      // White King on a8 (8th rank), Black King on c7, Black to move.
      // Game is NOT over yet, Black has one turn to also reach the 8th rank.
      game.load('K7/2k5/8/8/8/8/8/8 b - - 0 1');
      expect(game.gameOver, isFalse);

      // From the above position, Black moves King to c8.
      // Both kings are now on the 8th rank, so the game is over and it is a draw.
      final moves = game.generateMoves();
      final blackKingToC8 = moves.firstWhere((m) => m.fromAlgebraic == 'c7' && m.toAlgebraic == 'c8');
      game.makeMove(blackKingToC8);
      expect(game.gameOver, isTrue);
      expect(game.inDraw, isTrue);
    });
  });
}
