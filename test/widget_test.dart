import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
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
  void setCachedEvaluation(String fen, List<EngineEvaluation> evals) =>
      cache.put(variant, fen, evals);

  @override
  Future<void> setVariant(DatasetVariant variant) async {}

  @override
  Future<void> start() async {}

  @override
  Future<void> startSearch(String fen) async {}
}
