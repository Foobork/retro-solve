import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';

void main() {
  group('Antichess Chess Variant Tests', () {
    test('FEN loading and getters for Antichess', () {
      final game = AntichessChess();
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1';
      expect(Chess.validateFen(fen)['valid'], isTrue);

      final success = game.load(fen);
      expect(success, isTrue);
      expect(game.isAntichess, isTrue);
      expect(game.castling[PlayerColor.white], equals(0));
      expect(game.castling[PlayerColor.black], equals(0));
    });

    test('Castling is disabled even if FEN contains castling rights', () {
      final game = AntichessChess();
      // Load a FEN with castling rights KQkq
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');
      expect(game.castling[PlayerColor.white], equals(0));
      expect(game.castling[PlayerColor.black], equals(0));

      final moves = game.generateMoves();
      final castlingMoves = moves.where((m) => (m.flags & (Chess.bitsKsideCastle | Chess.bitsQsideCastle)) != 0).toList();
      expect(castlingMoves, isEmpty);
    });

    test('Captures are mandatory', () {
      final game = AntichessChess();
      // Load position where White pawn on e4 can capture Black pawn on d5
      // e4 d5: 1.e4 d5
      game.load('rnbqkbnr/ppp1pppp/8/3p4/4P3/8/PPPP1PPP/RNBQKBNR w - - 0 2');

      final moves = game.generateMoves();
      // Since exd5 is a capture move, captures are mandatory, so only capture moves are returned!
      expect(moves.every((m) => (m.flags & (Chess.bitsCapture | Chess.bitsEpCapture)) != 0), isTrue);
      expect(moves.length, equals(1));
      expect(moves.first.toAlgebraic, equals('d5'));
    });

    test('Pawn promotion to King is supported', () {
      final game = AntichessChess();
      // Load a position with a pawn about to promote
      game.load('8/P7/8/8/8/8/8/k6K w - - 0 1');

      final moves = game.generateMoves();
      final promotions = moves.where((m) => (m.flags & Chess.bitsPromotion) != 0).toList();
      expect(promotions, isNotEmpty);
      
      // Should include promotion to King!
      final promotesToKing = promotions.any((m) => m.promotion == king);
      expect(promotesToKing, isTrue);

      // Verify that standard promotions are also present
      expect(promotions.any((m) => m.promotion == queen), isTrue);
    });

    test('Game over when a side has no pieces left', () {
      final game = AntichessChess();
      // Load position where White only has 1 piece (a pawn) and it is about to be captured
      // Or simply load a position with 0 pieces for White
      game.load('8/8/8/8/8/8/8/k6K w - - 0 1');
      expect(game.gameOver, isFalse); // Both sides have 1 piece (kings)

      // Now load a position where one side has no pieces at all
      game.load('8/8/8/8/8/8/8/8 w - - 0 1');
      expect(game.gameOver, isTrue);
    });
  });
}
