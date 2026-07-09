import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';

void main() {
  group('Three-Check Chess Variant Tests', () {
    test('FEN validation and loading for 3check', () {
      final game = Chess();
      // Starting position with 3check FEN (7 fields)
      const startingFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3+3 0 1';
      expect(Chess.validateFen(startingFen)['valid'], isTrue);
      
      final success = game.load(startingFen);
      expect(success, isTrue);
      expect(game.isThreeCheck, isTrue);
      expect(game.checksCount[PlayerColor.white], equals(3));
      expect(game.checksCount[PlayerColor.black], equals(3));
      expect(game.generateFen(), equals(startingFen));
      expect(game.generateBfen(), equals('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3+3'));
    });

    test('Standard FEN loading defaults checks count to 3', () {
      final game = Chess();
      const standardFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';
      expect(Chess.validateFen(standardFen)['valid'], isTrue);

      final success = game.load(standardFen);
      expect(success, isTrue);
      expect(game.isThreeCheck, isFalse);
      expect(game.checksCount[PlayerColor.white], equals(3));
      expect(game.checksCount[PlayerColor.black], equals(3));
      expect(game.generateFen(), equals(standardFen));
    });

    test('Checks remaining count decrements on check', () {
      final game = Chess();
      // Start a 3check game
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3+3 0 1');
      
      // 1. e4
      game.move('e4');
      expect(game.checksCount[PlayerColor.white], equals(3));

      // 1... f6
      game.move('f6');
      expect(game.checksCount[PlayerColor.black], equals(3));

      // 2. Qh5+ (check!)
      game.move('Qh5+');
      // White checked Black, so White's remaining checks to deliver decreases to 2
      expect(game.checksCount[PlayerColor.white], equals(2));
      expect(game.checksCount[PlayerColor.black], equals(3));
    });

    test('Undo correctly restores check count', () {
      final game = Chess();
      game.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3+3 0 1');
      
      game.move('e4');
      game.move('f6');
      game.move('Qh5+');
      expect(game.checksCount[PlayerColor.white], equals(2));

      // Undo Qh5+
      game.undo();
      expect(game.checksCount[PlayerColor.white], equals(3));
    });

    test('Game over after three checks', () {
      final game = Chess();
      // Load a position where White has only 1 check remaining to deliver
      // rnbqkbnr/pppp1ppp/8/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 1+3 0 3
      game.load('rnbqkbnr/pppp1ppp/8/7Q/4P3/8/PPPP1PPP/RNB1KBNR w KQkq - 1+3 0 3');
      
      expect(game.checksCount[PlayerColor.white], equals(1));
      expect(game.gameOver, isFalse);
      expect(game.isThreeCheckGameOver, isFalse);
      expect(game.generateMoves(), isNotEmpty);

      // White plays Qxf7# (delivers game-ending check)
      game.move('Qxf7#');
      
      // White has 0 checks remaining to deliver
      expect(game.checksCount[PlayerColor.white], equals(0));
      expect(game.gameOver, isTrue);
      expect(game.isThreeCheckGameOver, isTrue);
      
      // Since game is over, no moves should be generated
      expect(game.generateMoves(), isEmpty);
      
      // Undo restores the state
      game.undo();
      expect(game.checksCount[PlayerColor.white], equals(1));
      expect(game.gameOver, isFalse);
      expect(game.isThreeCheckGameOver, isFalse);
      expect(game.generateMoves(), isNotEmpty);
    });
  });
}
