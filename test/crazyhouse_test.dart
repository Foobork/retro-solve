import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';

void main() {
  group('Crazyhouse Chess Variant Tests', () {
    test('FEN validation and loading for Crazyhouse', () {
      final game = CrazyhouseChess();
      // Starting position with empty pockets
      const startingFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
      expect(Chess.validateFen(startingFen)['valid'], isTrue);

      final success = game.load(startingFen);
      expect(success, isTrue);
      expect(game.isCrazyhouse, isTrue);
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(0));
      expect(game.pockets[PlayerColor.black]![PieceType.pawn], equals(0));
      expect(game.generateBfen(), equals('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq -'));
    });

    test('FEN with non-empty pockets', () {
      final game = CrazyhouseChess();
      // FEN containing White pocket: Q, R, B, N, P and Black pocket: q, r, b, n, p
      const fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[QRBNPqrbnp] w KQkq - 0 1';
      expect(Chess.validateFen(fen)['valid'], isTrue);

      final success = game.load(fen);
      expect(success, isTrue);
      expect(game.pockets[PlayerColor.white]![PieceType.queen], equals(1));
      expect(game.pockets[PlayerColor.white]![PieceType.rook], equals(1));
      expect(game.pockets[PlayerColor.white]![PieceType.bishop], equals(1));
      expect(game.pockets[PlayerColor.white]![PieceType.knight], equals(1));
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(1));

      expect(game.pockets[PlayerColor.black]![PieceType.queen], equals(1));
      expect(game.pockets[PlayerColor.black]![PieceType.rook], equals(1));
      expect(game.pockets[PlayerColor.black]![PieceType.bishop], equals(1));
      expect(game.pockets[PlayerColor.black]![PieceType.knight], equals(1));
      expect(game.pockets[PlayerColor.black]![PieceType.pawn], equals(1));

      expect(game.generateBfen(), equals('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[QRBNPqrbnp] w KQkq -'));
    });

    test('Generates drop moves when pocket has pieces', () {
      final game = CrazyhouseChess();
      // Load a FEN where White has a Knight in the pocket
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[N] w KQkq - 0 1');

      final moves = game.generateMoves();
      // White has a knight in the pocket, so there should be drop moves (like N@e3, N@e4, etc.)
      final dropMoves = moves.where((m) => (m.flags & Chess.bitsDrop) != 0).toList();
      expect(dropMoves, isNotEmpty);
      expect(dropMoves.any((m) => m.piece == PieceType.knight), isTrue);
      expect(dropMoves.any((m) => m.piece == PieceType.pawn), isFalse);

      // Verify pawns cannot be dropped on 1st or 8th ranks
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1');
      final movesWithPawn = game.generateMoves();
      final pawnDrops = movesWithPawn.where((m) => (m.flags & Chess.bitsDrop) != 0 && m.piece == PieceType.pawn).toList();
      expect(pawnDrops, isNotEmpty);
      for (final m in pawnDrops) {
        final rank = Chess.rank(m.to);
        expect(rank, isNot(equals(Chess.rank1)));
        expect(rank, isNot(equals(Chess.rank8)));
      }
    });

    test('Captured pieces go to pocket', () {
      final game = CrazyhouseChess();
      // Standard board
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1');

      // 1. e4
      game.move('e4');
      // 1... d5
      game.move('d5');
      // 2. exd5 (White pawn captures Black pawn)
      game.move('exd5');

      // White's pocket should now contain 1 Black pawn (which is stored as White pawn since White captured it and can drop it)
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(1));
    });

    test('Promoted pieces captured return as pawns', () {
      final game = CrazyhouseChess();
      // Load: White promoted Queen at a8, Black Rook at a5, Black King at g8, White King at h1.
      game.load('Q5k1/8/8/r7/8/8/8/7K[] b - - 0 1');

      // Mark the Queen at a8 as promoted
      game.promoted[Chess.squares['a8']!] = true;

      // Black Rook captures the promoted Queen: Rxa8
      game.move('Rxa8');

      // Since the Queen was promoted, capturing it should add a PAWN (not a Queen) to Black's pocket!
      expect(game.pockets[PlayerColor.black]![PieceType.pawn], equals(1));
      expect(game.pockets[PlayerColor.black]![PieceType.queen], equals(0));
    });

    test('Undo drops and captures correctly', () {
      final game = CrazyhouseChess();
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1');

      game.move('e4');
      game.move('d5');
      game.move('exd5'); // White captures pawn
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(1));

      // Make a move for Black first, e.g. Nc6, so it's White's turn again!
      game.move('Nc6');

      // White drops the pawn
      game.move('P@e5');
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(0));

      // Undo the drop
      game.undo();
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(1));
      expect(game.get('e5'), isNull);

      // Undo Black's Nc6 move
      game.undo();

      // Undo the capture
      game.undo();
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(0));
    });

    test('No redundant disambiguator when piece in pocket can drop to target square', () {
      final game = CrazyhouseChess();
      // White has Bishop on f1, e2 is empty, and White has a Bishop in hand [B]
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPP1PPP/RNBQKBNR[B] w KQkq - 0 1');

      final moves = game.generateMoves();
      final bishopMove = moves.firstWhere(
        (m) => (m.flags & Chess.bitsDrop) == 0 && m.fromAlgebraic == 'f1' && m.toAlgebraic == 'e2',
      );
      final dropMove = moves.firstWhere(
        (m) => (m.flags & Chess.bitsDrop) != 0 && m.piece == PieceType.bishop && m.toAlgebraic == 'e2',
      );

      // Bishop move to e2 must be Be2, NOT Bfe2
      expect(game.moveToSan(bishopMove), equals('Be2'));
      // Bishop drop to e2 must be B@e2
      expect(game.moveToSan(dropMove), equals('B@e2'));

      // Both can be played
      final game1 = game.copy();
      expect(game1.move('Be2'), isTrue);

      final game2 = game.copy();
      expect(game2.move('B@e2'), isTrue);

      // Redundant disambiguator input 'Bfe2' should also resolve to the board move
      final game3 = game.copy();
      expect(game3.move('Bfe2'), isTrue);
      expect(game3.get('e2')?.type, equals(PieceType.bishop));
      // Pocket bishop still in hand
      expect(game3.pockets[PlayerColor.white]![PieceType.bishop], equals(1));
    });

    test('Disambiguator is retained when multiple board pieces can move to target square', () {
      final game = CrazyhouseChess();
      // White has Bishop on f1 and Bishop on c4, e2 is empty, and White has a Bishop in hand [B]
      game.load('rnbqkbnr/pppppppp/8/8/2B5/8/PPPP1PPP/RNBQKBNR[B] w KQkq - 0 1');

      final moves = game.generateMoves();
      final bishopF1 = moves.firstWhere(
        (m) => (m.flags & Chess.bitsDrop) == 0 && m.fromAlgebraic == 'f1' && m.toAlgebraic == 'e2',
      );
      final bishopC4 = moves.firstWhere(
        (m) => (m.flags & Chess.bitsDrop) == 0 && m.fromAlgebraic == 'c4' && m.toAlgebraic == 'e2',
      );
      final bishopDrop = moves.firstWhere(
        (m) => (m.flags & Chess.bitsDrop) != 0 && m.piece == PieceType.bishop && m.toAlgebraic == 'e2',
      );

      // Board bishops must disambiguate each other
      expect(game.moveToSan(bishopF1), equals('Bfe2'));
      expect(game.moveToSan(bishopC4), equals('Bce2'));
      // Drop remains B@e2
      expect(game.moveToSan(bishopDrop), equals('B@e2'));
    });

    test('No redundant disambiguator for Knights, Queens, and Rooks when piece is in pocket', () {
      final game = CrazyhouseChess();

      // Knight: Ng1 to f3 with N in hand
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[N] w KQkq - 0 1');
      final nMove = game.generateMoves().firstWhere(
        (m) => (m.flags & Chess.bitsDrop) == 0 && m.fromAlgebraic == 'g1' && m.toAlgebraic == 'f3',
      );
      final nDrop = game.generateMoves().firstWhere(
        (m) => (m.flags & Chess.bitsDrop) != 0 && m.piece == PieceType.knight && m.toAlgebraic == 'f3',
      );
      expect(game.moveToSan(nMove), equals('Nf3'));
      expect(game.moveToSan(nDrop), equals('N@f3'));

      // Queen: Qd1 to d4 with Q in hand
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPP1PPPP/RNBQKBNR[Q] w KQkq - 0 1');
      final qMove = game.generateMoves().firstWhere(
        (m) => (m.flags & Chess.bitsDrop) == 0 && m.fromAlgebraic == 'd1' && m.toAlgebraic == 'd4',
      );
      final qDrop = game.generateMoves().firstWhere(
        (m) => (m.flags & Chess.bitsDrop) != 0 && m.piece == PieceType.queen && m.toAlgebraic == 'd4',
      );
      expect(game.moveToSan(qMove), equals('Qd4'));
      expect(game.moveToSan(qDrop), equals('Q@d4'));

      // Rook: Ra1 to a4 with R in hand
      game.load('rnbqkbnr/pppppppp/8/8/8/8/1PPPPPPP/RNBQKBNR[R] w KQkq - 0 1');
      final rMove = game.generateMoves().firstWhere(
        (m) => (m.flags & Chess.bitsDrop) == 0 && m.fromAlgebraic == 'a1' && m.toAlgebraic == 'a4',
      );
      final rDrop = game.generateMoves().firstWhere(
        (m) => (m.flags & Chess.bitsDrop) != 0 && m.piece == PieceType.rook && m.toAlgebraic == 'a4',
      );
      expect(game.moveToSan(rMove), equals('Ra4'));
      expect(game.moveToSan(rDrop), equals('R@a4'));
    });
  });
}
