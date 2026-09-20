import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/graph/position_eval.dart';

void main() {
  group('GameResult', () {
    test('fromInt maps values correctly', () {
      expect(GameResult.fromInt(1), equals(GameResult.whiteWins));
      expect(GameResult.fromInt(-1), equals(GameResult.blackWins));
      expect(GameResult.fromInt(0), equals(GameResult.draw));
      expect(GameResult.fromInt(null), isNull);
      expect(GameResult.fromInt(99), isNull);
    });

    test('isWinFor and isLossFor reflect turn perspective', () {
      expect(GameResult.whiteWins.isWinFor(true), isTrue);
      expect(GameResult.whiteWins.isWinFor(false), isFalse);
      expect(GameResult.whiteWins.isLossFor(false), isTrue);

      expect(GameResult.blackWins.isWinFor(false), isTrue);
      expect(GameResult.blackWins.isWinFor(true), isFalse);
      expect(GameResult.blackWins.isLossFor(true), isTrue);

      expect(GameResult.draw.isWinFor(true), isFalse);
      expect(GameResult.draw.isLossFor(true), isFalse);
    });
  });

  group('PositionEval Properties & Legacy Conversion', () {
    test('isDecisive, isMate, isDtzOnly flags', () {
      const mateEval = PositionEval(result: GameResult.whiteWins, dtw: 1);
      expect(mateEval.isDecisive, isTrue);
      expect(mateEval.isMate, isTrue);
      expect(mateEval.isDtzOnly, isFalse);

      const dtzEval = PositionEval(result: GameResult.blackWins, dtz: 3);
      expect(dtzEval.isDecisive, isTrue);
      expect(dtzEval.isMate, isFalse);
      expect(dtzEval.isDtzOnly, isTrue);

      const cpEval = PositionEval(cp: 120);
      expect(cpEval.isDecisive, isFalse);
      expect(cpEval.isMate, isFalse);
      expect(cpEval.isDtzOnly, isFalse);
    });

    test('toLegacyScore and fromLegacyScore round-trip', () {
      // Mate in 1 for White (1 ply): 1000 - 1 = 999.0
      const wMate1 = PositionEval(result: GameResult.whiteWins, dtw: 1);
      expect(wMate1.toLegacyScore(), equals(999.0));
      expect(PositionEval.fromLegacyScore(999.0), equals(wMate1));

      // Mate in 2 for Black (3 plies): -1000 + 3 = -997.0
      const bMate2 = PositionEval(result: GameResult.blackWins, dtw: 3);
      expect(bMate2.toLegacyScore(), equals(-997.0));
      expect(PositionEval.fromLegacyScore(-997.0), equals(bMate2));

      // DTZ 1 win for White: 950 - 1 = 949.0
      const wDtz1 = PositionEval(result: GameResult.whiteWins, dtz: 1);
      expect(wDtz1.toLegacyScore(), equals(949.0));
      expect(PositionEval.fromLegacyScore(949.0), equals(wDtz1));

      // DTZ 3 win for Black: -950 + 3 = -947.0
      const bDtz3 = PositionEval(result: GameResult.blackWins, dtz: 3);
      expect(bDtz3.toLegacyScore(), equals(-947.0));
      expect(PositionEval.fromLegacyScore(-947.0), equals(bDtz3));

      // General mate without DTZ: +/-950.0
      const wMateGen = PositionEval(result: GameResult.whiteWins);
      expect(wMateGen.toLegacyScore(), equals(950.0));
      expect(PositionEval.fromLegacyScore(950.0), equals(wMateGen));

      // Draw / neutral 0.0
      const drawEval = PositionEval(result: GameResult.draw, cp: 0);
      expect(drawEval.toLegacyScore(), equals(0.0));
      const cp0 = PositionEval(cp: 0);
      expect(cp0.toLegacyScore(), equals(0.0));
      expect(PositionEval.fromLegacyScore(0.0), equals(cp0));

      // Centipawns: +1.50
      const cp150 = PositionEval(cp: 150);
      expect(cp150.toLegacyScore(), equals(1.50));
      expect(PositionEval.fromLegacyScore(1.50), equals(cp150));
    });
  });

  group('PositionEval.format', () {
    test('formats exact mates correctly for positions and moves', () {
      const wMate1Ply = PositionEval(result: GameResult.whiteWins, dtw: 1);
      expect(wMate1Ply.format(), equals('+M1'));
      expect(wMate1Ply.format(isMove: true), equals('+M1'));

      const wMate0 = PositionEval(result: GameResult.whiteWins, dtw: 0);
      expect(wMate0.format(), equals('+M0'));

      const bMate3Plies = PositionEval(result: GameResult.blackWins, dtw: 3);
      expect(bMate3Plies.format(), equals('-M2'));
      expect(bMate3Plies.format(isMove: true), equals('-M2'));
    });

    test('formats DTZ-only and pseudo-mates cleanly', () {
      const wDtz1 = PositionEval(result: GameResult.whiteWins, dtz: 1);
      expect(wDtz1.format(), equals('+DTZ 1'));

      const bDtz3 = PositionEval(result: GameResult.blackWins, dtz: 3);
      expect(bDtz3.format(), equals('-DTZ 3'));

      const wMateNoDtz = PositionEval(result: GameResult.whiteWins);
      expect(wMateNoDtz.format(), equals('+Mate'));

      const bMateNoDtz = PositionEval(result: GameResult.blackWins);
      expect(bMateNoDtz.format(), equals('-Mate'));
    });

    test('formats draws and heuristic centipawns', () {
      expect(const PositionEval(result: GameResult.draw).format(), equals('0.00'));
      expect(const PositionEval(cp: 235).format(), equals('+2.35'));
      expect(const PositionEval(cp: -80).format(), equals('-0.80'));
      expect(const PositionEval().format(), equals('—'));
    });
  });

  group('PositionEval.compare (Move Ordering)', () {
    test('White to move prefers winning lines with shorter DTW', () {
      const mate1 = PositionEval(result: GameResult.whiteWins, dtw: 1);
      const mate3 = PositionEval(result: GameResult.whiteWins, dtw: 3);
      expect(PositionEval.compare(mate1, mate3, true), lessThan(0));
      expect(PositionEval.compare(mate3, mate1, true), greaterThan(0));
    });

    test('White to move prefers exact DTW over DTZ-only win', () {
      const exactMate = PositionEval(result: GameResult.whiteWins, dtw: 4);
      const dtzWin = PositionEval(result: GameResult.whiteWins, dtz: 1);
      expect(PositionEval.compare(exactMate, dtzWin, true), lessThan(0));
      expect(PositionEval.compare(dtzWin, exactMate, true), greaterThan(0));
    });

    test('White to move prefers smaller DTZ among DTZ-only wins', () {
      const dtz1 = PositionEval(result: GameResult.whiteWins, dtz: 1);
      const dtz3 = PositionEval(result: GameResult.whiteWins, dtz: 3);
      expect(PositionEval.compare(dtz1, dtz3, true), lessThan(0));
      expect(PositionEval.compare(dtz3, dtz1, true), greaterThan(0));
    });

    test('White to move prefers win over positive cp, draw, and loss', () {
      const win = PositionEval(result: GameResult.whiteWins, dtz: 1);
      const cpPlus5 = PositionEval(cp: 500);
      const draw = PositionEval(result: GameResult.draw);
      const cpMinus2 = PositionEval(cp: -200);
      const loss = PositionEval(result: GameResult.blackWins, dtw: 2);

      expect(PositionEval.compare(win, cpPlus5, true), lessThan(0));
      expect(PositionEval.compare(cpPlus5, draw, true), lessThan(0));
      expect(PositionEval.compare(draw, cpMinus2, true), lessThan(0));
      expect(PositionEval.compare(cpMinus2, loss, true), lessThan(0));
    });

    test('Black to move prefers Black wins with shorter DTW and smaller DTZ', () {
      const bMate1 = PositionEval(result: GameResult.blackWins, dtw: 1);
      const bMate3 = PositionEval(result: GameResult.blackWins, dtw: 3);
      const bDtz1 = PositionEval(result: GameResult.blackWins, dtz: 1);
      const bDtz5 = PositionEval(result: GameResult.blackWins, dtz: 5);

      expect(PositionEval.compare(bMate1, bMate3, false), lessThan(0));
      expect(PositionEval.compare(bMate1, bDtz1, false), lessThan(0));
      expect(PositionEval.compare(bDtz1, bDtz5, false), lessThan(0));
    });

    test('Losing side resists by preferring larger DTW or larger DTZ', () {
      const bMate10 = PositionEval(result: GameResult.blackWins, dtw: 10);
      const bMate2 = PositionEval(result: GameResult.blackWins, dtw: 2);
      expect(PositionEval.compare(bMate10, bMate2, true), lessThan(0));

      const bDtz5 = PositionEval(result: GameResult.blackWins, dtz: 5);
      const bDtz1 = PositionEval(result: GameResult.blackWins, dtz: 1);
      expect(PositionEval.compare(bDtz5, bDtz1, true), lessThan(0));
    });

    test('Black to move prefers win over negative cp, draw, and loss', () {
      const win = PositionEval(result: GameResult.blackWins, dtz: 1);
      const cpMinus3 = PositionEval(cp: -316);
      const cpMinus029 = PositionEval(cp: -29);
      const draw = PositionEval(result: GameResult.draw);
      const cpPlus084 = PositionEval(cp: 84);
      const loss = PositionEval(result: GameResult.whiteWins, dtw: 2);

      expect(PositionEval.compare(win, cpMinus3, false), lessThan(0));
      expect(PositionEval.compare(cpMinus3, cpMinus029, false), lessThan(0));
      expect(PositionEval.compare(cpMinus029, draw, false), lessThan(0));
      expect(PositionEval.compare(draw, cpPlus084, false), lessThan(0));
      expect(PositionEval.compare(cpPlus084, loss, false), lessThan(0));
    });

    test('Draw is not treated as advantage even with anomalous non-zero cp', () {
      const g6 = PositionEval(cp: -316);
      const c3 = PositionEval(cp: -29);
      const drawWithAnomalousCp = PositionEval(result: GameResult.draw, cp: -52);

      // Black to move: g6 (-3.16) > c3 (-0.29) > draw (0.00)
      expect(PositionEval.compare(g6, c3, false), lessThan(0));
      expect(PositionEval.compare(c3, drawWithAnomalousCp, false), lessThan(0));
      expect(PositionEval.compare(drawWithAnomalousCp, c3, false), greaterThan(0));
    });

    test('Evaluated moves sort before null/unrated moves', () {
      const evalMove = PositionEval(result: GameResult.blackWins, dtw: 1);
      expect(PositionEval.compare(evalMove, null, true), lessThan(0));
      expect(PositionEval.compare(null, evalMove, true), greaterThan(0));
      expect(PositionEval.compare(null, null, true), equals(0));
    });
  });
}
