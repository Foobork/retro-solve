import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/pgn_parser.dart';

void main() {
  group('PgnParser Tests', () {
    test('parses simple linear PGN', () {
      const pgn = '''
[Event "Test"]
[Site "Local"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 1-0
''';
      final games = PgnParser.parse(pgn);
      expect(games.length, equals(1));
      final game = games.first;
      expect(game.headers['Event'], equals('Test'));
      expect(game.headers['Result'], equals('1-0'));

      final root = game.root;
      expect(root.children.length, equals(1));
      expect(root.children[0].san, equals('e4'));
      expect(root.children[0].children[0].san, equals('e5'));
      expect(root.children[0].children[0].children[0].san, equals('Nf3'));
      expect(root.children[0].children[0].children[0].children[0].san, equals('Nc6'));
      expect(root.children[0].children[0].children[0].children[0].children[0].san, equals('Bb5'));
    });

    test('parses PGN with variations and sub-variations', () {
      const pgn = '''
1. e4 e5 (1... c5 2. Nf3) (1... e6) 2. Nf3 Nc6
''';
      final games = PgnParser.parse(pgn);
      expect(games.length, equals(1));
      final root = games.first.root;

      // e4
      expect(root.children.length, equals(1));
      final e4 = root.children[0];
      expect(e4.san, equals('e4'));

      // From e4, there should be 3 branches: e5 (main line), c5 (var 1), e6 (var 2)
      expect(e4.children.map((c) => c.san).toList(), equals(['e5', 'c5', 'e6']));

      // e5 branch leads to Nf3 -> Nc6
      final e5 = e4.children[0];
      expect(e5.children.length, equals(1));
      expect(e5.children[0].san, equals('Nf3'));
      expect(e5.children[0].children[0].san, equals('Nc6'));

      // c5 branch leads to Nf3
      final c5 = e4.children[1];
      expect(c5.children.length, equals(1));
      expect(c5.children[0].san, equals('Nf3'));
    });

    test('parses lichess_study file with comments, NAGs, and deep variations', () {
      final file = File('lichess_study_atomic-chess-introduction-to-1-nf3-f6-2-nd4-nh6-3-e3_3-ng4_by_ProgramFOX_2016.12.25.pgn');
      final content = file.existsSync()
          ? file.readAsStringSync()
          : '''[Event "Atomic Chess: Introduction to 1. Nf3 f6 2. Nd4 Nh6 3. e3: 3... Ng4"]
[Site "https://lichess.org/study/xxxx"]
[Variant "Atomic"]
[ChapterName "3... Ng4"]

1. Nf3 { An opening move. } 1... f6 2. Nd4 Nh6 (2... e5 3. Nf5) 3. e3 \$1 Ng4 { A deep variation. } (3... d5 4. Bb5+ c6 5. Be2 (5. Bf1 e5)) 4. Qxg4 *
''';

      final games = PgnParser.parse(content);
      expect(games.length, equals(1));
      final game = games.first;
      expect(game.headers['Variant'], equals('Atomic'));
      expect(game.headers['ChapterName'], equals('3... Ng4'));

      final root = game.root;
      expect(root.children.length, equals(1));
      expect(root.children[0].san, equals('Nf3'));
      expect(root.totalNodes, greaterThanOrEqualTo(5));
    });

    test('parses Chess.com Crazyhouse PGN normalizing drop notation in tree', () {
      final path = File('test/data/jesuslovesyouforreal vs 2071 Crazyhouse 2026-09-15.pgn').existsSync()
          ? 'test/data/jesuslovesyouforreal vs 2071 Crazyhouse 2026-09-15.pgn'
          : 'data/jesuslovesyouforreal vs 2071 Crazyhouse 2026-09-15.pgn';
      final file = File(path);
      expect(file.existsSync(), isTrue);

      final games = PgnParser.parse(file.readAsStringSync());
      expect(games.length, equals(1));
      final game = games.first;
      expect(game.variant, equals('Crazyhouse'));

      final moves = <String>[];
      PgnNode? curr = game.root;
      while (curr != null && curr.children.isNotEmpty) {
        final next = curr.children.first;
        if (next.san != null) moves.add(next.san!);
        curr = next;
      }

      expect(moves.length, equals(44));
      // Drops are normalized to standard SAN
      expect(moves[10], equals('P@d5')); // was @0_rPd5
      expect(moves[11], equals('B@d4')); // was B@2_yBd4
      expect(moves[20], equals('B@b3')); // was B@0_rBb3
      expect(moves[21], equals('P@e6')); // was @2_yPe6
      expect(moves[22], equals('N@g5')); // was N@0_rNg5
      expect(moves[32], equals('P@d7')); // was @0_rPd7
      expect(moves[36], equals('B@e6')); // was B@0_rBe6
      expect(moves[38], equals('R@d7')); // was R@0_rRd7
      expect(moves[40], equals('P@b4')); // was @0_rPb4
      expect(moves[43], equals('Q@h1')); // was Q@2_yQh1
    });
  });
}
