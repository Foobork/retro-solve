import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/chess/pgn_parser.dart';

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

    test('Black in check can interpose with drop move N@f8 or board move Bf8', () {
      final game = CrazyhouseChess();
      const fen = 'r1bnQ1k1/1pp1bp1r/p6B/3pP3/3Pn3/2PQ4/P1P1BPPP/R4RK1[PPnnp] b - - 0 1';
      expect(game.load(fen), isTrue);

      expect(game.inCheck, isTrue);
      expect(game.pockets[PlayerColor.black]![PieceType.knight], equals(2));
      expect(game.pockets[PlayerColor.black]![PieceType.pawn], equals(1));
      expect(game.pockets[PlayerColor.white]![PieceType.pawn], equals(2));

      final moves = game.generateMoves();
      final moveSans = moves.map((m) => game.moveToSan(m)).toList();

      expect(moveSans.contains('N@f8'), isTrue);
      expect(moveSans.contains('Bf8'), isTrue);

      // Verify N@f8 can be played and resolves the check
      final gameDrop = game.copy();
      expect(gameDrop.move('N@f8'), isTrue);
      expect(gameDrop.inCheck, isFalse);
      expect(gameDrop.get('f8')?.type, equals(PieceType.knight));
      expect(gameDrop.get('f8')?.color, equals(PlayerColor.black));
      expect(gameDrop.pockets[PlayerColor.black]![PieceType.knight], equals(1));

      // Verify Bf8 can be played and resolves the check
      final gameMove = game.copy();
      expect(gameMove.move('Bf8'), isTrue);
      expect(gameMove.inCheck, isFalse);
      expect(gameMove.get('f8')?.type, equals(PieceType.bishop));
      expect(gameMove.get('f8')?.color, equals(PlayerColor.black));
      expect(gameMove.get('e7'), isNull);
    });

    test('normalizeDropNotation normalizes Chess.com, UCI, and standard drop notations', () {
      // Chess.com notation with player identifiers
      expect(Chess.normalizeDropNotation('@0_rPd5'), equals('P@d5'));
      expect(Chess.normalizeDropNotation('B@2_yBd4'), equals('B@d4'));
      expect(Chess.normalizeDropNotation('B@0_rBb3'), equals('B@b3'));
      expect(Chess.normalizeDropNotation('@2_yPe6'), equals('P@e6'));
      expect(Chess.normalizeDropNotation('N@0_rNg5'), equals('N@g5'));
      expect(Chess.normalizeDropNotation('@0_rPd7'), equals('P@d7'));
      expect(Chess.normalizeDropNotation('B@0_rBe6'), equals('B@e6'));
      expect(Chess.normalizeDropNotation('R@0_rRd7'), equals('R@d7'));
      expect(Chess.normalizeDropNotation('@0_rPb4'), equals('P@b4'));
      expect(Chess.normalizeDropNotation('Q@2_yQh1'), equals('Q@h1'));
      expect(Chess.normalizeDropNotation('Q@2_yQh1#'), equals('Q@h1#'));
      expect(Chess.normalizeDropNotation('B@0_rBb3+'), equals('B@b3+'));

      // Pawn drop without piece letter
      expect(Chess.normalizeDropNotation('@d5'), equals('P@d5'));
      expect(Chess.normalizeDropNotation('@e6+'), equals('P@e6+'));

      // UCI lowercase drop notation
      expect(Chess.normalizeDropNotation('p@d5'), equals('P@d5'));
      expect(Chess.normalizeDropNotation('b@d4'), equals('B@d4'));
      expect(Chess.normalizeDropNotation('n@g5'), equals('N@g5'));
      expect(Chess.normalizeDropNotation('r@d7'), equals('R@d7'));
      expect(Chess.normalizeDropNotation('q@h1'), equals('Q@h1'));

      // Standard SAN drops remain unchanged
      expect(Chess.normalizeDropNotation('P@d5'), equals('P@d5'));
      expect(Chess.normalizeDropNotation('B@d4'), equals('B@d4'));

      // Normal non-drop moves remain unchanged
      expect(Chess.normalizeDropNotation('e4'), equals('e4'));
      expect(Chess.normalizeDropNotation('Nf3'), equals('Nf3'));
      expect(Chess.normalizeDropNotation('O-O'), equals('O-O'));
    });

    test('Replays Chess.com Crazyhouse PGN file successfully to checkmate', () {
      final pgnFile = File('test/data/jesuslovesyouforreal vs 2071 Crazyhouse 2026-09-15.pgn');
      expect(pgnFile.existsSync(), isTrue);

      final pgnText = pgnFile.readAsStringSync();
      final games = PgnParser.parse(pgnText);
      expect(games.length, equals(1));

      final gameObj = games.first;
      expect(gameObj.variant, equals('Crazyhouse'));
      expect(gameObj.headers['White'], equals('jesuslovesyouforreal'));
      expect(gameObj.headers['Black'], equals('Party_Of_One'));
      expect(gameObj.headers['Result'], equals('0-1'));

      final game = CrazyhouseChess();
      expect(game.isCrazyhouse, isTrue);

      // Collect all moves in sequence
      final moveSans = <String>[];
      PgnNode? curr = gameObj.root;
      while (curr != null && curr.children.isNotEmpty) {
        final next = curr.children.first;
        if (next.san != null) {
          moveSans.add(next.san!);
        }
        curr = next;
      }

      expect(moveSans.length, equals(44)); // 22 full moves = 44 half-moves
      expect(moveSans[10], equals('P@d5'));
      expect(moveSans[11], equals('B@d4'));
      expect(moveSans[43], equals('Q@h1'));

      for (int i = 0; i < moveSans.length; i++) {
        final san = moveSans[i];
        final success = game.move(san);
        expect(success, isTrue, reason: 'Move #$i ($san) failed from FEN ${game.fen}');
      }

      // 22... Q@h1# is checkmate
      expect(game.inCheckmate, isTrue);
      expect(game.turn, equals(PlayerColor.white));
    });
  });
}
