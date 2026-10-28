import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/polyglot_zobrist.dart';

void main() {
  group('Polyglot Zobrist Tests', () {
    test('Calculates exact Polyglot Zobrist key for 1. e3 and 1. e3 c5', () {
      const fenE3 = 'rnbqkbnr/pppppppp/8/8/8/4P3/PPPP1PPP/RNBQKBNR b - - 0 1';
      final kE3 = PolyglotZobrist.computeKey(fenE3);
      expect(kE3.toRadixString(16).toUpperCase(), equals('902CF901E54FDBD1'));

      const fenE3C5 = 'rnbqkbnr/pp1ppppp/8/2p5/8/4P3/PPPP1PPP/RNBQKBNR w - - 0 2';
      final kE3C5 = PolyglotZobrist.computeKey(fenE3C5);
      expect(kE3C5.toRadixString(16).toUpperCase(), equals('765D28AF1A08D0AC'));
    });
  });
}
