import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:retro_solve/retro_solve.dart';

void main() {
  testWidgets('RetroSolve widget smoke test', (WidgetTester tester) async {
    final engineService = FairyStockfishService(initialVariant: DatasetVariant.koth);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.koth,
        engineService: engineService,
      ),
    );
    expect(find.byType(RetroSolve), findsOneWidget);
  });

  testWidgets('Antichess move g1=B renders BlackBishop on the board', (WidgetTester tester) async {
    final engineService = FairyStockfishService(initialVariant: DatasetVariant.antichess);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.antichess,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    // Load custom position into the controller
    const fen = '5N2/Q3n3/8/8/8/N7/P1P1P1p1/R3K3 b - - 0 1';
    final state = tester.state(find.byType(HomePage)) as dynamic;
    state.controller.loadFen(fen);
    await tester.pumpAndSettle();

    // Verify initial pawn on g2
    expect(state.controller.game.get('g2')?.type.name, equals('p'));

    // Make promotion move g1=B
    state.controller.makeMoveWithNormalNotation('g1=B');
    await tester.pumpAndSettle();

    // Verify promoted piece is Bishop
    expect(state.controller.game.get('g1')?.type.name, equals('b'));
    expect(state.controller.game.get('g1')?.color.name, equals('black'));
  });

  testWidgets('Engine mate ply conversions are correct across all winning and losing perspectives', (WidgetTester tester) async {
    final engineService = FairyStockfishService(initialVariant: DatasetVariant.standard);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state(find.byType(HomePage)) as dynamic;

    // 1. White to move, White wins in 2 moves (mate +2 in UCI): 2*2 - 1 = 3 plies -> +997.0
    const wWin2 = EngineEvaluation(mate: 2);
    expect(state.engineEvalToGraphScore(wWin2.asWhitePerspective(whiteToMove: true), true), equals(997.0));

    // 2. White to move, White loses in 2 moves (mate -2 in UCI): 2*2 = 4 plies -> -996.0
    const wLose2 = EngineEvaluation(mate: -2);
    expect(state.engineEvalToGraphScore(wLose2.asWhitePerspective(whiteToMove: true), true), equals(-996.0));

    // 3. Black to move, Black wins in 2 moves (mate +2 in UCI): 2*2 - 1 = 3 plies -> -997.0
    const bWin2 = EngineEvaluation(mate: 2);
    expect(state.engineEvalToGraphScore(bWin2.asWhitePerspective(whiteToMove: false), false), equals(-997.0));

    // 4. Black to move, Black loses in 2 moves (mate -2 in UCI): 2*2 = 4 plies -> +996.0
    const bLose2 = EngineEvaluation(mate: -2);
    expect(state.engineEvalToGraphScore(bLose2.asWhitePerspective(whiteToMove: false), false), equals(996.0));
  });
}
