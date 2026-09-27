import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:test/test.dart';
import 'package:retro_solve/dataset_variant.dart';

void main() {
  test('parse cp score from info line', () {
    final eval = parseUciInfo(
      'info depth 12 seldepth 19 score cp 34 nodes 31594 nps 700000 pv e2e4 e7e5',
    );
    expect(eval, isNotNull);
    expect(eval!.centipawns, equals(34));
    expect(eval.mate, isNull);
  });

  test('parse mate score from info line', () {
    final eval = parseUciInfo(
      'info depth 14 seldepth 24 score mate -3 nodes 90214 nps 1200000',
    );
    expect(eval, isNotNull);
    expect(eval!.mate, equals(-3));
    expect(eval.centipawns, isNull);
  });

  test('return null when score is absent', () {
    final eval = parseUciInfo('info nodes 1200 nps 300000');
    expect(eval, isNull);
  });

  test('map standard dataset to chess uci variant', () {
    expect(uciVariantForDataset(DatasetVariant.standard), equals('chess'));
  });

  test('map koth dataset to kingofthehill uci variant', () {
    expect(uciVariantForDataset(DatasetVariant.koth), equals('kingofthehill'));
  });

  test('asWhitePerspective keeps cp when white to move', () {
    const e = EngineEvaluation(centipawns: 50);
    expect(e.asWhitePerspective(whiteToMove: true).centipawns, equals(50));
  });

  test('asWhitePerspective negates cp when black to move', () {
    const e = EngineEvaluation(centipawns: 50);
    expect(e.asWhitePerspective(whiteToMove: false).centipawns, equals(-50));
  });

  test('asWhitePerspective negates mate when black to move', () {
    const e = EngineEvaluation(mate: 3);
    expect(e.asWhitePerspective(whiteToMove: false).mate, equals(-3));

    // When Black is to move and Black is losing (mate -2 in UCI):
    const losingBlackEval = EngineEvaluation(mate: -2);
    // After asWhitePerspective, it becomes +2 (favoring White)
    expect(losingBlackEval.asWhitePerspective(whiteToMove: false).mate, equals(2));
  });

  test('toString omits cp prefix for centipawns and includes lines', () {
    const e = EngineEvaluation(centipawns: 123);
    expect(e.toString(), equals('Eval: +1.23'));
  });

  test('pseudo-mate evaluation identifies +-15000 cp and formats as +Mate/-Mate', () {
    const pseudoLoss = EngineEvaluation(centipawns: -15265);
    const pseudoWin = EngineEvaluation(centipawns: 15265);
    const normal = EngineEvaluation(centipawns: 1200);

    expect(pseudoLoss.isPseudoMate, isTrue);
    expect(pseudoWin.isPseudoMate, isTrue);
    expect(normal.isPseudoMate, isFalse);

    expect(pseudoLoss.toString(), contains('-Mate'));
    expect(pseudoWin.toString(), contains('+Mate'));
    expect(pseudoLoss.toString(), isNot(contains('-152.65')));
  });

  test('EngineService default search depth', () {
    expect(EngineService.defaultSearchDepth, equals(16));
  });

  group('DTW calculation from UCI mate score', () {
    test('standard/atomic variant: positive mate M is 2M - 1 plies', () {
      // Mate in 1 = 1 ply
      const m1 = 1;
      const dtw1 = 2 * m1 - 1;
      expect(dtw1, equals(1));

      // Mate in 7 = 13 plies
      const m7 = 7;
      const dtw7 = 2 * m7 - 1;
      expect(dtw7, equals(13));
    });

    test('standard/atomic variant: negative mate -M is 2M plies', () {
      // Losing in 1 move (opponent delivers mate) = 2 plies
      const mMinus1 = -1;
      final dtwMinus1 = 2 * mMinus1.abs();
      expect(dtwMinus1, equals(2));

      // Losing in 7 moves = 14 plies
      const mMinus7 = -7;
      final dtwMinus7 = 2 * mMinus7.abs();
      expect(dtwMinus7, equals(14));
    });

    test('antichess variant: winning side mate M is 2M plies', () {
      const m1 = 1;
      const dtwAntichess = 2 * m1;
      expect(dtwAntichess, equals(2));
    });
  });

  group('EngineCache DTW and decisive score preservation', () {
    const fen = '4k3/8/7P/8/8/8/1PP5/3K4 w - - 0 1';
    final cache = EngineCache();

    test('eval with DTW overrides tablebase +Mate lacking DTW', () {
      // 1. Initial tablebase evaluation: proven win (+Mate), but DTW is null
      const tbEval = EngineEvaluation(
        centipawns: 20000,
        candidateMove: 'h6h7',
        depth: 16,
      );
      cache.put(DatasetVariant.atomic, fen, [tbEval], force: true);
      expect(cache.get(DatasetVariant.atomic, fen)?.first.dtw, isNull);
      expect(cache.get(DatasetVariant.atomic, fen)?.first.centipawns, equals(20000));

      // 2. FSF discovers mate 7 (dtw: 13)
      const fsfMateEval = EngineEvaluation(
        mate: 7,
        dtw: 13,
        candidateMove: 'h6h7',
        depth: 16,
      );
      cache.put(DatasetVariant.atomic, fen, [fsfMateEval], force: true);

      // Verify that the evaluation with DTW overrode the one without DTW
      final updated = cache.get(DatasetVariant.atomic, fen);
      expect(updated, isNotNull);
      expect(updated!.first.mate, equals(7));
      expect(updated.first.dtw, equals(13));
    });

    test('evaluation without DTW cannot override existing evaluation with DTW', () {
      final freshCache = EngineCache();
      const mateEvalWithDtw = EngineEvaluation(
        mate: 7,
        dtw: 13,
        candidateMove: 'h6h7',
        depth: 16,
      );
      freshCache.put(DatasetVariant.atomic, fen, [mateEvalWithDtw], force: true);

      // Try putting an eval without DTW
      const evalWithoutDtw = EngineEvaluation(
        centipawns: 20000,
        candidateMove: 'h6h7',
        depth: 20,
      );
      freshCache.put(DatasetVariant.atomic, fen, [evalWithoutDtw], force: true);

      // Should still retain the DTW evaluation
      final current = freshCache.get(DatasetVariant.atomic, fen);
      expect(current!.first.dtw, equals(13));
      expect(current.first.mate, equals(7));
    });

    test('heuristic evaluation cannot override decisive +Mate evaluation', () {
      final freshCache = EngineCache();
      const tbEval = EngineEvaluation(
        centipawns: 20000,
        candidateMove: 'h6h7',
      );
      freshCache.put(DatasetVariant.atomic, fen, [tbEval], force: true);

      // FSF shallow search yields +4.50 cp (non-decisive)
      const shallowCpEval = EngineEvaluation(
        centipawns: 450,
        depth: 10,
        candidateMove: 'h6h7',
      );
      freshCache.put(DatasetVariant.atomic, fen, [shallowCpEval], force: false);

      // Decisive +Mate must not be overwritten
      final current = freshCache.get(DatasetVariant.atomic, fen, minDepth: 0);
      expect(current!.first.centipawns, equals(20000));
      expect(current.first.isPseudoMate, isTrue);
    });
  });
}
