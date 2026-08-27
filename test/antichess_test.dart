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

    test('Validate FEN rejects pawns on 1st or 8th rank', () {
      expect(Chess.validateFen('5N2/Q3n3/8/8/8/N7/P1P1P3/R3K1p1 w - - 0 1')['valid'], isFalse);
      expect(Chess.validateFen('P7/8/8/8/8/8/8/8 w - - 0 1')['valid'], isFalse);
      expect(Chess.validateFen('8/8/8/8/8/8/8/P7 w - - 0 1')['valid'], isFalse);
    });

    test('Antichess generates exactly 5 promotion piece options (Q, R, B, N, K) without duplicates', () {
      final game = AntichessChess();
      game.load('8/4P3/8/8/8/8/8/8 w - - 0 1');
      final moves = game.generateMoves();
      expect(moves.length, equals(5));
      final pieces = moves.map((m) => m.promotion).toSet();
      expect(pieces, equals({queen, rook, bishop, knight, king}));
    });

    test('Black pawn promotion to King and other pieces', () {
      final game = AntichessChess();
      game.load('8/8/8/8/8/8/4p3/8 b - - 0 1');
      final moves = game.generateMoves();
      expect(moves.length, equals(5));
      final pieces = moves.map((m) => m.promotion).toSet();
      expect(pieces, equals({queen, rook, bishop, knight, king}));

      // Make a promotion to King
      final kingPromoMove = moves.firstWhere((m) => m.promotion == king);
      game.makeMove(kingPromoMove);
      expect(game.get('e1')?.type, equals(king));
      expect(game.get('e1')?.color, equals(PlayerColor.black));
    });

    test('Antichess move g1=B and copy deep cloning preserves original board piece', () {
      const fen = '5N2/Q3n3/8/8/8/N7/P1P1P1p1/R3K3 b - - 0 1';
      final game = AntichessChess();
      game.load(fen);

      // Make g1=B move
      final success = game.move('g1=B');
      expect(success, isTrue);
      expect(game.fen, startsWith('5N2/Q3n3/8/8/8/N7/P1P1P3/R3K1b1'));
      expect(game.get('g1')?.type, equals(bishop));
      expect(game.get('g1')?.color, equals(PlayerColor.black));

      // Simulate a background copy listener running legal moves and undoing them
      final copy = game.copy();
      for (final m in copy.generateMoves()) {
        copy.makeMove(m);
        copy.undo();
      }

      // Ensure the original game still has the promoted Bishop on g1!
      expect(game.get('g1')?.type, equals(bishop));
      expect(game.get('g1')?.color, equals(PlayerColor.black));
    });

    test('Antichess generates exactly 10 moves for 5Nn1/p7/8/8/3Q4/N7/P1P1P1p1/R3K3 without duplicate promotions', () {
      const fen = '5Nn1/p7/8/8/3Q4/N7/P1P1P1p1/R3K3 b - - 0 1';
      final game = AntichessChess();
      game.load(fen);

      final moves = game.generateMoves();
      final sans = moves.map(game.moveToSan).toList();
      print('Moves from 5Nn1 position: $sans');

      // Total 10 moves: a6, a5, Ne7, Nf6, Nh6, g1=Q, g1=R, g1=B, g1=N, g1=K
      expect(sans.length, equals(10));
      expect(sans.toSet().length, equals(10));
      expect(sans.where((s) => s == 'g1=K').length, equals(1));
      expect(sans, containsAll(['a6', 'a5', 'Ne7', 'Nf6', 'Nh6', 'g1=Q', 'g1=R', 'g1=B', 'g1=N', 'g1=K']));
    });
  });
}
