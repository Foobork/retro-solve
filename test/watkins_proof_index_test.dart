import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/watkins_proof_index.dart';

void main() {
  test('WatkinsZobrist and WatkinsProofIndexManager lookup on easy12 and e3c5', () {
    final game = AntichessChess();
    expect(game.move('e3'), isTrue);

    // Check 1... a5 from easy12.rev.proof.idx if present
    if (File('easy12.rev.proof.idx').existsSync()) {
      final gA5 = game.copy();
      expect(gA5.move('a5'), isTrue);
      final entryA5 = WatkinsProofIndexManager.instance.lookupBfen(gA5.bfen);
      expect(entryA5, isNotNull);
      expect(entryA5!.dtw, equals(110)); // +M55
      expect(entryA5.bestMoveUci, isNotNull);
    }

    // Check 1... c5 and 2. Bb5 from e3c5.rev3.proof.idx if present
    if (File('e3c5.rev3.proof.idx').existsSync()) {
      final gC5 = game.copy();
      expect(gC5.move('c5'), isTrue);
      final entryC5 = WatkinsProofIndexManager.instance.lookupBfen(gC5.bfen);
      expect(entryC5, isNotNull);
      expect(entryC5!.dtw, equals(282)); // +M141
      expect(entryC5.bestMoveUci, equals('f1b5'));

      expect(gC5.move('Bb5'), isTrue);
      final entryBb5 = WatkinsProofIndexManager.instance.lookupBfen(gC5.bfen);
      expect(entryBb5, isNotNull);
      expect(entryBb5!.dtw, equals(281)); // +M141

      // Check all 21 legal Black replies to 2. Bb5
      final blackMoves = gC5.generateMoves();
      expect(blackMoves.length, equals(21));
      int maxChildDtw = 0;
      for (final m in blackMoves) {
        gC5.makeMove(m);
        final childEntry = WatkinsProofIndexManager.instance.lookupBfen(gC5.bfen);
        expect(
          childEntry,
          isNotNull,
          reason: 'Missing Black reply ${m.fromAlgebraic}${m.toAlgebraic} (${gC5.bfen})',
        );
        if (childEntry!.dtw > maxChildDtw) {
          maxChildDtw = childEntry.dtw;
        }
        gC5.undoMove();
      }
      expect(maxChildDtw, equals(280)); // 2... Qc7 is 280 plies (+M140)

      const posBfen = 'r5n1/p5k1/n6r/8/5P2/4P1P1/PNP5/R3K3 w - -';
      final ePos = WatkinsProofIndexManager.instance.lookupBfen(posBfen);
      expect(ePos, isNotNull);
      expect(ePos!.dtw, equals(246));
      expect(ePos.bestMoveUci, equals('b2a4'));

      const bfenNxb6 = 'r5n1/p5k1/nN6/8/5P2/4P1P1/P1P5/R3K3 b - -';
      final eNxb6 = WatkinsProofIndexManager.instance.lookupBfen(bfenNxb6);
      expect(eNxb6, isNotNull);
      expect(eNxb6!.dtw, equals(243));

      const bfenAxb6 = 'r5n1/6k1/np6/8/5P2/4P1P1/P1P5/R3K3 w - -';
      final eAxb6 = WatkinsProofIndexManager.instance.lookupBfen(bfenAxb6);
      expect(eAxb6, isNotNull);
      expect(eAxb6!.dtw, equals(242));
      expect(eAxb6.bestMoveUci, equals('e1d2'));
    }
  });
}
