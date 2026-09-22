import 'package:flutter/material.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/retro_solve.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/gui/chess_board.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

class _NoopEngineService extends FairyStockfishService {
  final _controller = StreamController<List<EngineEvaluation>>.broadcast();

  @override
  Stream<List<EngineEvaluation>> get evaluationStream => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> startSearch(String fen) async {}

  @override
  Future<void> dispose() async {
    _controller.close();
  }
}

class _MockExploreEngineService extends FairyStockfishService {
  final _controller = StreamController<List<EngineEvaluation>>.broadcast();
  bool _searching = false;
  Timer? _searchTimer;

  @override
  bool get isEngineAvailable => true;

  @override
  Stream<List<EngineEvaluation>> get evaluationStream => _controller.stream;

  @override
  bool get isSearching => _searching;

  @override
  Future<void> start() async {}

  @override
  Future<void> startSearch(String fen) async {
    _searching = true;
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 30), () {
      final chess = Chess();
      if (chess.load(fen)) {
        final moves = chess.generateMoves();
        if (moves.isNotEmpty) {
          final preferred = moves.firstWhere(
            (m) =>
                '${m.fromAlgebraic}${m.toAlgebraic}' == 'e2e4' ||
                '${m.fromAlgebraic}${m.toAlgebraic}' == 'e7e5',
            orElse: () => moves.first,
          );
          final uci =
              '${preferred.fromAlgebraic}${preferred.toAlgebraic}${preferred.promotion?.name ?? ''}'
                  .toLowerCase();
          _controller.add([
            EngineEvaluation(
              candidateMove: uci,
              centipawns: chess.turn == PlayerColor.white ? 30 : -30,
              depth: 16,
              fen: fen,
            ),
          ]);
        }
      }
      _searching = false;
    });
  }

  @override
  Future<void> dispose() async {
    _searchTimer?.cancel();
    _controller.close();
  }
}

void main() {
  testWidgets('KOTH variant does not render check badges or status', (WidgetTester tester) async {
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.koth,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    // No check badge numbers like '3' should be rendered on KOTH startup
    expect(find.text('3'), findsNothing);
    expect(find.textContaining('Checks remaining'), findsNothing);
  });

  testWidgets('threeCheck variant renders checks remaining badges and status', (WidgetTester tester) async {
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.threeCheck,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    // In Three-Check, both kings have 3 checks remaining on startup,
    // so we should find two widgets displaying '3' (one for each king badge).
    expect(find.text('3'), findsNWidgets(2));

    // The status label should also display the checks remaining status
    expect(find.textContaining('3+3'), findsOneWidget);
  });

  testWidgets('renders mate score formatted as +M/M and parses mate input', (WidgetTester tester) async {
    resetGraph();

    const startBfen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    const childBfen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
    final vertex = graph.addVertex(startBfen);
    vertex.inDatabase = true;
    graph.addLink(startBfen, childBfen);
    graph.assign(childBfen, 991.0);
    graph.solveBfen(startBfen);

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();
    
    // Trigger board notification to run _update()
    final ChessBoard board = tester.widget(find.byType(ChessBoard));
    board.controller.value = board.controller.value.copy();
    
    // Trigger UI update
    await tester.pump();

    // The text field should display the formatted computed score in parentheses
    expect(find.text('(+M5)'), findsOneWidget);

    // Now let's try typing a mate score in the input and submitting it
    await tester.enterText(find.byType(TextField), '+M3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    // Verify that the assigned score is correctly parsed to 1000 - 6 = 994.0
    expect(vertex.assignedScore, equals(994.0));
    // Since child variation is solved (+M5), the backsolved computed evaluation takes precedence in display
    expect(find.text('(+M5)'), findsOneWidget);
  });

  testWidgets('displays assigned evaluation directly when no child moves are computed', (WidgetTester tester) async {
    resetGraph();

    const startBfen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    final vertex = graph.addVertex(startBfen);
    vertex.inDatabase = true;

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    // Type +M3 on leaf position
    await tester.enterText(find.byType(TextField), '+M3');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(vertex.assignedScore, equals(994.0));
    expect(find.text('+M3'), findsOneWidget);
  });

  testWidgets('move comparator sorts evaluated moves before unevaluated moves symmetrically', (WidgetTester tester) async {
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<HomePageState>(find.byType(HomePage));
    final cmpWhite = state.compareMoves(PlayerColor.white);

    final evalMove = MoveInfo('Bxd7', 972.0);
    final noEvalMove = MoveInfo('Nxd7', null);

    // Evaluated move must sort BEFORE un-evaluated move (-1)
    expect(cmpWhite(evalMove, noEvalMove), equals(-1));
    // Un-evaluated move must sort AFTER evaluated move (1)
    expect(cmpWhite(noEvalMove, evalMove), equals(1));
    // Two un-evaluated moves compare equal (0)
    expect(cmpWhite(noEvalMove, MoveInfo('Qxd7', null)), equals(0));
  });

  testWidgets('unevaluated known moves are excluded from getEvaluatedMoveSans but included in getKnownMoveSans', (WidgetTester tester) async {
    resetGraph();

    const rootBfen = 'rnbqk1nr/pppN1ppp/8/8/8/8/PPPPPPPR/RNBQKB2 b - -';
    const child1Bfen = 'rn1qk1nr/pppb1ppp/8/8/8/8/PPPPPPPR/RNBQKB2 w - -'; // Bxd7 (evaluated)
    const child2Bfen = 'r1bqk1nr/pppn1ppp/8/8/8/8/PPPPPPPR/RNBQKB2 w - -'; // Nxd7 (unevaluated, has links)

    final rootVertex = graph.addVertex(rootBfen);
    rootVertex.inDatabase = true;

    graph.addLink(rootBfen, child1Bfen);
    graph.assign(child1Bfen, 972.0);

    graph.addLink(rootBfen, child2Bfen);
    // child2 has links but no evaluation
    graph.addLink(child2Bfen, 'r1bqk1nr/pppn1ppR/8/8/8/8/PPPPPPP1/RNBQKB2 b - -');

    graph.solveBfen(rootBfen);

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.antichess,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<HomePageState>(find.byType(HomePage));
    state.controller.game.load('$rootBfen 0 1');
    final ChessBoard board = tester.widget(find.byType(ChessBoard));
    board.controller.value = board.controller.value.copy();
    await tester.pump();

    final knownSans = state.getKnownMoveSans();
    final evaluatedSans = state.getEvaluatedMoveSans();

    // Both moves are known in repertoire
    expect(knownSans.contains('Bxd7'), isTrue);
    expect(knownSans.contains('Nxd7'), isTrue);

    // Only evaluated move is in getEvaluatedMoveSans
    expect(evaluatedSans.contains('Bxd7'), isTrue);
    expect(evaluatedSans.contains('Nxd7'), isFalse);
  });

  testWidgets('unevaluated frontier legal moves are excluded from known moves list', (WidgetTester tester) async {
    resetGraph();

    const rootBfen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    const child1Bfen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -'; // e4 (evaluated)
    const child2Bfen = 'rnbqkbnr/pppppppp/8/8/3P4/8/PPP1PPPP/RNBQKBNR b KQkq -'; // d4 (unevaluated frontier in graph)

    final rootVertex = graph.addVertex(rootBfen);
    rootVertex.inDatabase = true;

    graph.addLink(rootBfen, child1Bfen);
    graph.assign(child1Bfen, 991.0);

    // child2 is linked as frontier node with no eval and no links of its own
    graph.addLink(rootBfen, child2Bfen);

    graph.solveBfen(rootBfen);

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<HomePageState>(find.byType(HomePage));
    final knownSans = state.getKnownMoveSans();

    // Only evaluated move e4 should be known; d4 (frontier with no eval/links) must not be in knownSans
    expect(knownSans.contains('e4'), isTrue);
    expect(knownSans.contains('d4'), isFalse);
    expect(knownSans.length, equals(1));
  });

  testWidgets('handles mate in 200 in retrograde solving, input parsing, and UI rendering', (WidgetTester tester) async {
    resetGraph();

    const rootBfen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq -';
    const childBfen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';

    // Child has White winning in 200 moves (Black to move, 398 plies to mate: 1000 - 398 = 602.0)
    final rootVertex = graph.addVertex(rootBfen);
    rootVertex.inDatabase = true;
    graph.addLink(rootBfen, childBfen);
    graph.assign(childBfen, 602.0);
    graph.solveBfen(rootBfen);

    // Root (White to move) adjusts child score 602.0 by subtracting 1 ply -> 601.0 (399 plies = mate in 200)
    expect(rootVertex.computedScore, equals(601.0));

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<HomePageState>(find.byType(HomePage));
    // Verify formatting at root position
    expect(state.formatScore(rootVertex.computed!), equals('+M200'));

    // Test typing +M200 directly
    await tester.enterText(find.byType(TextField), '+M200');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(rootVertex.assignedScore, equals(600.0));
    expect(state.formatScore(rootVertex.assigned!), equals('+M200'));
  });

  testWidgets('explore terminates without infinite thrashing when candidates have no assignable score', (WidgetTester tester) async {
    resetGraph();

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

    // Set pseudo-mate candidates that do not auto-populate
    const pseudoEvals = [
      EngineEvaluation(candidateMove: 'h2h3', centipawns: -15265, fen: antichessFen, depth: 16),
      EngineEvaluation(candidateMove: 'a4a5', centipawns: -15265, fen: antichessFen, depth: 16),
      EngineEvaluation(candidateMove: 'h1a1', centipawns: -15265, fen: antichessFen, depth: 16),
    ];
    state.setEngineEvalsForTesting(pseudoEvals);
    await tester.pump();

    // Start exploration
    final exploreFuture = state.startExploring();

    // Advance clocks to let exploration attempt each candidate once and exit cleanly
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      if (!state.isExploring) break;
    }

    await exploreFuture;
    expect(state.isExploring, isFalse);
  });

  testWidgets('explore evaluates first candidate move and displays it with evaluation', (WidgetTester tester) async {
    resetGraph();

    final engineService = _MockExploreEngineService();
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<HomePageState>(find.byType(HomePage));

    // Start exploration
    final exploreFuture = state.startExploring();

    // Advance clocks to let exploration complete root and child move
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!state.isExploring) break;
    }
    await exploreFuture;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    final knownMoves = state.knownMoves;
    expect(knownMoves.any((m) => m.move == 'e4'), isTrue);
    final e4Move = knownMoves.firstWhere((m) => m.move == 'e4');
    expect(e4Move.eval, isNotNull);
  });

  testWidgets('analyze mode analyzes moves and solves once at the end', (WidgetTester tester) async {
    resetGraph();

    final engineService = _MockExploreEngineService();
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: engineService,
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<HomePageState>(find.byType(HomePage));

    const pgn = '''
[Event "Test Game"]
[Variant "Standard"]

1. e4
''';

    final analyzeFuture = state.analyzeGame(pgn);

    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (!state.isAnalyzingGame) break;
    }
    await analyzeFuture;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(state.isAnalyzingGame, isFalse);
    expect(state.isExploring, isFalse);

    final knownMoves = state.knownMoves;
    expect(knownMoves.any((m) => m.move == 'e4'), isTrue);
  });
}
