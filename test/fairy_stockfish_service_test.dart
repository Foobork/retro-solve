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
  });

  test('toString omits cp prefix for centipawns and includes lines', () {
    const e = EngineEvaluation(centipawns: 123);
    expect(e.toString(), equals('Eval: +1.23'));
  });
}
