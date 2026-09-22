import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/gui/chess_board.dart';
import 'package:retro_solve/gui/chess_board_controller.dart';
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
    expect(state.controller.game.get('g1')?.color, equals(PlayerColor.black));
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

    // Antichess: Loser makes the final move, so plies are inverted (Win: 2*M plies, Loss: 2*M - 1 plies)
    // 5. Antichess White to move, White wins in 2 moves (mate +2 in UCI): 2*2 = 4 plies -> +996.0
    expect(state.engineEvalToGraphScore(wWin2.asWhitePerspective(whiteToMove: true), true, variant: DatasetVariant.antichess), equals(996.0));

    // 6. Antichess White to move, White loses in 2 moves (mate -2 in UCI): 2*2 - 1 = 3 plies -> -997.0
    expect(state.engineEvalToGraphScore(wLose2.asWhitePerspective(whiteToMove: true), true, variant: DatasetVariant.antichess), equals(-997.0));

    // 7. Antichess Black to move, Black wins in 2 moves (mate +2 in UCI): 2*2 = 4 plies -> -996.0
    expect(state.engineEvalToGraphScore(bWin2.asWhitePerspective(whiteToMove: false), false, variant: DatasetVariant.antichess), equals(-996.0));

    // 8. Antichess Black to move, Black loses in 2 moves (mate -2 in UCI): 2*2 - 1 = 3 plies -> +997.0
    expect(state.engineEvalToGraphScore(bLose2.asWhitePerspective(whiteToMove: false), false, variant: DatasetVariant.antichess), equals(997.0));

    // 9. Antichess user bug scenario: White to move plays Ne2; in child position Black to move is losing in 18 moves (-M18).
    // Child position eval from Black's perspective: mate -18.
    const bLose18 = EngineEvaluation(mate: -18);
    final childScore = state.engineEvalToGraphScore(bLose18.asWhitePerspective(whiteToMove: false), false, variant: DatasetVariant.antichess);
    expect(childScore, equals(965.0)); // 1000 - (2*18 - 1) = 965.0 (35 plies remaining in child)
    // When displayed in the movelist for move Ne2, isMoveScore is true and must format to +M18 (not +M19)
    expect(state.formatScore(childScore, isMoveScore: true), equals('+M18'));

    // 10. Antichess terminal position: White has won on the board (White is stalemated with no legal moves).
    // Engine reports score mate 0. Must resolve to +1000.0 (+M0) instead of -M0.
    const antichessWinFen = '1n5r/2p4p/8/3k4/6b1/6P1/7r/8 w - - 0 1';
    const mate0Eval = EngineEvaluation(mate: 0, fen: antichessWinFen);
    final mate0Score = state.engineEvalToGraphScore(mate0Eval, true, variant: DatasetVariant.antichess);
    expect(mate0Score, equals(1000.0));
    expect(state.formatScore(mate0Score), equals('+M0'));

    // 11. Mate in 50 (1000 - 99 = 901.0): formats as +M50
    const wWin50 = EngineEvaluation(mate: 50);
    final score50 = state.engineEvalToGraphScore(wWin50.asWhitePerspective(whiteToMove: true), true, variant: DatasetVariant.standard);
    expect(score50, equals(901.0));
    expect(state.formatScore(score50), equals('+M50'));

    // 12. Mate in 51 (1000 - 101 = 899.0): formats as +M51 (previously failed due to 900.0 threshold)
    const wWin51 = EngineEvaluation(mate: 51);
    final score51 = state.engineEvalToGraphScore(wWin51.asWhitePerspective(whiteToMove: true), true, variant: DatasetVariant.standard);
    expect(score51, equals(899.0));
    expect(state.formatScore(score51), equals('+M51'));

    // 13. Mate in 200 (1000 - 399 = 601.0): formats as +M200
    const wWin200 = EngineEvaluation(mate: 200);
    final score200 = state.engineEvalToGraphScore(wWin200.asWhitePerspective(whiteToMove: true), true, variant: DatasetVariant.standard);
    expect(score200, equals(601.0));
    expect(state.formatScore(score200), equals('+M200'));

    // 14. Black winning in 200 moves (score -200 from Black's perspective): formats as -M200 from White perspective
    final bWin200 = state.engineEvalToGraphScore(wWin200.asWhitePerspective(whiteToMove: false), false, variant: DatasetVariant.standard);
    expect(bWin200, equals(-601.0));
    expect(state.formatScore(bWin200), equals('-M200'));

    // 15. Parsing mate inputs: +M200, -M200, +M51
    expect(state.parseScore('+M200'), equals(600.0));
    expect(state.formatScore(state.parseScore('+M200')!), equals('+M200'));
    expect(state.parseScore('-M200'), equals(-600.0));
    expect(state.formatScore(state.parseScore('-M200')!), equals('-M200'));
    expect(state.parseScore('+M51'), equals(898.0));
    expect(state.formatScore(state.parseScore('+M51')!), equals('+M51'));

    // 16. Pseudo-mate from engine (e.g. +-15265 cp) is converted to decisive evaluation (+Mate / -Mate)
    const pseudoLossEval = EngineEvaluation(centipawns: -15265);
    const pseudoWinEval = EngineEvaluation(centipawns: 15265);
    expect(pseudoLossEval.isPseudoMate, isTrue);
    expect(pseudoWinEval.isPseudoMate, isTrue);
    expect(state.engineEvalToGraphScore(pseudoLossEval, true), equals(-950.0));
    expect(state.engineEvalToGraphScore(pseudoWinEval, true), equals(950.0));
    expect(state.engineEvalToPositionEval(pseudoLossEval, true), equals(const PositionEval(result: GameResult.blackWins)));
    expect(state.engineEvalToPositionEval(pseudoWinEval, true), equals(const PositionEval(result: GameResult.whiteWins)));
    expect(pseudoLossEval.toString().contains('-Mate'), isTrue);
    expect(pseudoWinEval.toString().contains('+Mate'), isTrue);
    expect(state.formatScore(-152.65), equals('-Mate'));
    expect(state.formatScore(152.65), equals('+Mate'));
    expect(state.formatScore(state.engineEvalToPositionEval(pseudoWinEval, true)), equals('+Mate'));
    expect(state.formatScore(state.engineEvalToPositionEval(pseudoLossEval, true)), equals('-Mate'));

    // 17. Tablebase pseudo-mate with depth 100 receives decisive mate score
    const tbWinEval = EngineEvaluation(centipawns: 20000, depth: 100);
    const tbLossEval = EngineEvaluation(centipawns: -20000, depth: 100);
    final tbWinScore = state.engineEvalToGraphScore(tbWinEval, true);
    final tbLossScore = state.engineEvalToGraphScore(tbLossEval, true);
    expect(tbWinScore, isNotNull);
    expect(tbWinScore!, greaterThan(Graph.mateThreshold));
    expect(tbLossScore, isNotNull);
    expect(tbLossScore!, lessThan(-Graph.mateThreshold));

    // 18. Parsing pseudo-mate and legacy DTZ inputs: +Mate, -Mate, +DTZ 1, -DTZ 3, +Mate (DTZ 1), -Mate (DTZ 3)
    expect(state.parseScore('+Mate'), equals(950.0));
    expect(state.parseScore('-Mate'), equals(-950.0));
    expect(state.parseScore('+DTZ 1'), equals(950.0));
    expect(state.parseScore('-DTZ 3'), equals(-950.0));
    expect(state.parseScore('+Mate (DTZ 1)'), equals(950.0));
    expect(state.parseScore('-Mate (DTZ 3)'), equals(-950.0));
  });

  testWidgets('Pseudo-mate evaluations render -Mate/+Mate and never -152.65 in engine widget', (WidgetTester tester) async {
    final engineService = FairyStockfishService(initialVariant: DatasetVariant.antichess);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.antichess,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    const antichessFen = '8/p1pkpp1p/7b/2p5/P4p2/1p6/7P/7R w - - 0 1';
    final state = tester.state(find.byType(HomePage)) as dynamic;
    state.controller.loadFen(antichessFen);
    await tester.pumpAndSettle();

    // Candidate moves with -15265 centipawns (pseudo-mate from engine)
    const pseudoEvals = [
      EngineEvaluation(candidateMove: 'h2h3', centipawns: -15265, fen: antichessFen, depth: 16),
      EngineEvaluation(candidateMove: 'a4a5', centipawns: -15265, fen: antichessFen, depth: 16),
      EngineEvaluation(candidateMove: 'h1a1', centipawns: -15265, fen: antichessFen, depth: 16),
    ];
    state.setEngineEvalsForTesting(pseudoEvals);
    await tester.pump();

    // Must display -Mate, never -152.65
    expect(find.text('-Mate'), findsAtLeastNWidgets(1));
    expect(find.text('-152.65'), findsNothing);
  });

  testWidgets('Antichess stalemated White win renders +M0 in engine evaluation display', (WidgetTester tester) async {
    final engineService = FairyStockfishService(initialVariant: DatasetVariant.antichess);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.antichess,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    const antichessWinFen = '1n5r/2p4p/8/3k4/6b1/6P1/7r/8 w - - 0 1';
    final state = tester.state(find.byType(HomePage)) as dynamic;
    state.controller.loadFen(antichessWinFen);
    await tester.pumpAndSettle();

    // Directly supply an engine evaluation with mate: 0 (from Fairy-Stockfish terminal score)
    const mate0Eval = EngineEvaluation(mate: 0, fen: antichessWinFen, depth: 0);
    state.setEngineEvalsForTesting([mate0Eval]);
    await tester.pump();

    // Verify engine display row shows +M0, never -M0
    expect(find.text('+M0'), findsAtLeastNWidgets(1));
    expect(find.text('-M0'), findsNothing);
  });

  testWidgets('Crazyhouse layout renders board and pockets without overflow in wide and narrow layouts', (WidgetTester tester) async {
    final engineService = FairyStockfishService(initialVariant: DatasetVariant.crazyhouse);
    
    // Test wide layout (1000x700)
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.crazyhouse,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    // Verify no exception / overflow
    expect(tester.takeException(), isNull);
    expect(find.byType(ChessBoard), findsOneWidget);

    // Test narrow layout (400x800)
    tester.view.physicalSize = const Size(400, 800);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.crazyhouse,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('ChessBoard disables dragging and ignores pointers when user moves are disabled', (WidgetTester tester) async {
    final controller = ChessBoardController();
    bool enableUserMoves = true;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return ChessBoard(
                controller: controller,
                enableUserMoves: enableUserMoves,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // When enableUserMoves is true, draggables have maxSimultaneousDrags == 1
    var draggables = tester.widgetList<Draggable<PieceMoveData>>(find.byType(Draggable<PieceMoveData>));
    expect(draggables, isNotEmpty);
    for (final draggable in draggables) {
      expect(draggable.maxSimultaneousDrags, equals(1));
    }

    // Now disable user moves
    enableUserMoves = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              return ChessBoard(
                controller: controller,
                enableUserMoves: enableUserMoves,
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // When enableUserMoves is false, all draggables have maxSimultaneousDrags == 0
    draggables = tester.widgetList<Draggable<PieceMoveData>>(find.byType(Draggable<PieceMoveData>));
    expect(draggables, isNotEmpty);
    for (final draggable in draggables) {
      expect(draggable.maxSimultaneousDrags, equals(0));
    }
  });

  testWidgets('Engine stabilization does not freeze when search finishes before depth 16', (WidgetTester tester) async {
    final mockService = MockEngineService(variant: DatasetVariant.antichess);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.antichess,
        engineService: mockService,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    const antichessFen = 'rnbqkbn1/ppppp2r/8/5p2/8/5P2/PPPPP1PP/RNBQKB1R b - - 0 1';
    final state = tester.state(find.byType(HomePage)) as dynamic;
    state.controller.loadFen(antichessFen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Simulate search finished at depth 11 (isSearching = false)
    mockService.setSearching(false);
    state.setEngineEvalsForTesting([
      const EngineEvaluation(depth: 11, centipawns: -12, candidateMove: 'h7h2', fen: antichessFen)
    ]);
    await tester.pump();

    // Calling waitForEngineStabilization while pumping clock
    final stabilizationFuture = state.waitForEngineStabilization();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));
    await stabilizationFuture;
    expect(tester.takeException(), isNull);
  });

  testWidgets('ChessBoard highlights the last move played, updates on next move, and clears on undo/reset', (WidgetTester tester) async {
    final mockService = MockEngineService(variant: DatasetVariant.standard);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: mockService,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final state = tester.state(find.byType(HomePage)) as dynamic;

    // 1. Initially no last-move highlight
    expect(find.byKey(const ValueKey('last-move-from-e2')), findsNothing);
    expect(find.byKey(const ValueKey('last-move-to-e4')), findsNothing);

    // 2. Make move e4
    state.controller.makeMoveWithNormalNotation('e4');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('last-move-from-e2')), findsOneWidget);
    expect(find.byKey(const ValueKey('last-move-to-e4')), findsOneWidget);

    // 3. Make move e5
    state.controller.makeMoveWithNormalNotation('e5');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('last-move-from-e2')), findsNothing);
    expect(find.byKey(const ValueKey('last-move-to-e4')), findsNothing);
    expect(find.byKey(const ValueKey('last-move-from-e7')), findsOneWidget);
    expect(find.byKey(const ValueKey('last-move-to-e5')), findsOneWidget);

    // 4. Undo move e5
    state.controller.undoMove();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('last-move-from-e2')), findsOneWidget);
    expect(find.byKey(const ValueKey('last-move-to-e4')), findsOneWidget);
    expect(find.byKey(const ValueKey('last-move-from-e7')), findsNothing);
    expect(find.byKey(const ValueKey('last-move-to-e5')), findsNothing);

    // 5. Undo move e4
    state.controller.undoMove();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('last-move-from-e2')), findsNothing);
    expect(find.byKey(const ValueKey('last-move-to-e4')), findsNothing);
  });

  testWidgets('Crazyhouse drop highlights destination square without board origin square', (WidgetTester tester) async {
    final mockService = MockEngineService(variant: DatasetVariant.crazyhouse);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.crazyhouse,
        engineService: mockService,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final state = tester.state(find.byType(HomePage)) as dynamic;
    // Load a position with a pawn in White's pocket:
    const fenWithPocket = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[P] w KQkq - 0 1';
    state.controller.loadFen(fenWithPocket);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    state.controller.makeMoveWithNormalNotation('P@e4');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byKey(const ValueKey('last-move-to-e4')), findsOneWidget);
    // There should be no origin square highlighted on the board
    expect(find.byWidgetPredicate((widget) {
      if (widget.key is ValueKey<String>) {
        final keyVal = (widget.key as ValueKey<String>).value;
        return keyVal.startsWith('last-move-from-');
      }
      return false;
    }), findsNothing);
  });

  testWidgets('Antichess promotion dialog shows King on the left beside Queen and promotes to King', (WidgetTester tester) async {
    final game = AntichessChess();
    game.load('8/P7/8/8/8/8/8/7b w - - 0 1');
    final controller = ChessBoardController.fromGame(game);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: ChessBoard(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final a7Finder = find.byKey(const ValueKey('drag-a7'));
    final a8Finder = find.byKey(const ValueKey('target-a8'));
    expect(a7Finder, findsOneWidget);
    expect(a8Finder, findsOneWidget);

    final a7Center = tester.getCenter(a7Finder);
    final a8Center = tester.getCenter(a8Finder);

    final gesture = await tester.startGesture(a7Center);
    await tester.pump();
    await gesture.moveTo(a8Center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Choose promotion'), findsOneWidget);

    final kingPromoFinder = find.byKey(const ValueKey('promo-k'));
    final queenPromoFinder = find.byKey(const ValueKey('promo-q'));
    expect(kingPromoFinder, findsOneWidget);
    expect(queenPromoFinder, findsOneWidget);

    final kingX = tester.getTopLeft(kingPromoFinder).dx;
    final queenX = tester.getTopLeft(queenPromoFinder).dx;
    expect(kingX, lessThan(queenX));

    await tester.tap(kingPromoFinder);
    await tester.pumpAndSettle();

    expect(find.text('Choose promotion'), findsNothing);
    expect(controller.game.get('a8')?.type.name, equals('k'));
  });

  testWidgets('Standard chess promotion dialog does not show King button', (WidgetTester tester) async {
    final game = Chess();
    game.load('8/P7/8/8/8/8/8/7k w - - 0 1');
    final controller = ChessBoardController.fromGame(game);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 400,
              height: 400,
              child: ChessBoard(controller: controller),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final a7Center = tester.getCenter(find.byKey(const ValueKey('drag-a7')));
    final a8Center = tester.getCenter(find.byKey(const ValueKey('target-a8')));

    final gesture = await tester.startGesture(a7Center);
    await tester.pump();
    await gesture.moveTo(a8Center);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.text('Choose promotion'), findsOneWidget);
    expect(find.byKey(const ValueKey('promo-k')), findsNothing);
    expect(find.byKey(const ValueKey('promo-q')), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('Engine pseudomate (+Mate) is auto-populated and recorded in the database', (WidgetTester tester) async {
    final mockService = MockEngineService(variant: DatasetVariant.standard);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: mockService,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    const fen = '8/8/8/8/8/4k3/8/4K2R w - - 0 1';
    final state = tester.state(find.byType(HomePage)) as dynamic;
    state.controller.loadFen(fen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final bfen = state.controller.game.bfen;
    expect(graph.v[bfen]?.assigned, isNull);

    // Emit pseudo-mate (+20000 cp) from engine evaluation stream
    mockService.emit([
      EngineEvaluation(
        centipawns: 20000,
        depth: 16,
        candidateMove: 'h1h3',
        fen: state.controller.game.fen,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 250));

    // Node must be auto-populated in graph and marked as inDatabase
    expect(graph.v[bfen]?.assigned, equals(const PositionEval(result: GameResult.whiteWins)));
    expect(graph.v[bfen]?.inDatabase, isTrue);
    expect(state.formatScore(graph.v[bfen]?.assigned), equals('+Mate'));

    // Also verify for Black to move and Black is winning (-Mate in White perspective)
    const bWinFen = '8/8/8/8/8/4k3/8/4K2r b - - 0 1';
    state.controller.loadFen(bWinFen);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final bWinBfen = state.controller.game.bfen;
    mockService.emit([
      EngineEvaluation(
        centipawns: 20000, // Black's perspective: winning -> White's perspective: -20000
        depth: 16,
        candidateMove: 'h1h2',
        fen: state.controller.game.fen,
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 250));

    expect(graph.v[bWinBfen]?.assigned, equals(const PositionEval(result: GameResult.blackWins)));
    expect(graph.v[bWinBfen]?.inDatabase, isTrue);
    expect(state.formatScore(graph.v[bWinBfen]?.assigned), equals('-Mate'));
  });

  testWidgets('Solve action triggers visual indicator and disables board while running', (WidgetTester tester) async {
    final mockService = MockEngineService(variant: DatasetVariant.koth);
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.koth,
        engineService: mockService,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final state = tester.state(find.byType(HomePage)) as dynamic;
    expect(state.isSolving, isFalse);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    // Verify solve indicator renders when solving is active
    state.setSolvingForTesting(true, progress: 0.5, status: 'Testing solve progress...');
    await tester.pump();

    expect(state.isSolving, isTrue);
    expect(find.byType(LinearProgressIndicator), findsWidgets);
    expect(find.text('Testing solve progress...'), findsWidgets);

    // Verify solve indicator clears when done
    state.setSolvingForTesting(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(state.isSolving, isFalse);
    expect(find.text('Testing solve progress...'), findsNothing);
  });
}

class MockEngineService implements EngineService {
  MockEngineService({required this.variant, EngineCache? cache}) : cache = cache ?? EngineCache();

  @override
  final DatasetVariant variant;

  @override
  final EngineCache cache;

  @override
  bool get isNNUE => false;

  @override
  bool get isEngineAvailable => true;

  bool _isSearching = false;
  @override
  bool get isSearching => _isSearching;

  void setSearching(bool searching) => _isSearching = searching;

  final _evalController = StreamController<List<EngineEvaluation>>.broadcast();
  @override
  Stream<List<EngineEvaluation>> get evaluationStream => _evalController.stream;

  void emit(List<EngineEvaluation> evals) => _evalController.add(evals);

  @override
  int get cacheSize => cache.size;

  @override
  void clearCache() => cache.clear();

  @override
  Future<void> dispose() async => _evalController.close();

  @override
  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16}) async => null;

  @override
  List<EngineEvaluation>? getCachedEvaluation(String fen, {int minDepth = 16}) =>
      cache.get(variant, fen, minDepth: minDepth);

  @override
  Future<void> newGame() async {}

  @override
  void setCachedEvaluation(String fen, List<EngineEvaluation> evals, {bool force = false}) =>
      cache.put(variant, fen, evals, force: force);

  @override
  Future<void> setVariant(DatasetVariant variant) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> startSearch(String fen) async {}
}
