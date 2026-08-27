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
}
