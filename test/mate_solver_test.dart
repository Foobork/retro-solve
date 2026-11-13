import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/retro_solve.dart';

class _MockMateEngineService extends FairyStockfishService {
  final _controller = StreamController<List<EngineEvaluation>>.broadcast();
  bool _searching = false;
  Timer? _searchTimer;
  final Map<String, List<EngineEvaluation>> responses;

  _MockMateEngineService({this.responses = const {}});

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
    _searchTimer = Timer(const Duration(milliseconds: 20), () {
      if (responses.containsKey(fen)) {
        _controller.add(responses[fen]!);
      } else {
        // Default evaluation
        final chess = Chess();
        if (chess.load(fen)) {
          final moves = chess.generateMoves();
          if (moves.isNotEmpty) {
            final m = moves.first;
            final uci = '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}'.toLowerCase();
            _controller.add([
              EngineEvaluation(
                candidateMove: uci,
                centipawns: chess.turn == PlayerColor.white ? 100 : -100,
                depth: 16,
                fen: fen,
              ),
            ]);
          }
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
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetGraph();
  });

  group('Mate Solver Mode Tests', () {
    testWidgets('Immediate FSF confirmed mate proves position without expanding moves', (WidgetTester tester) async {
      const scholarsFen = 'r1bqkb1r/pppp1ppp/2n5/4p2Q/2B1P3/8/PPPP1PPP/RNB1K1NR w KQkq - 4 4';
      final engineService = _MockMateEngineService(
        responses: {
          scholarsFen: const [
            EngineEvaluation(
              candidateMove: 'h5f7',
              mate: 1,
              depth: 16,
              fen: scholarsFen,
            ),
          ],
        },
      );

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));
      state.controller.load(scholarsFen);
      await tester.pumpAndSettle();

      final solverFuture = state.startMateSolver(maxDepth: 10);
      expect(state.isMateSolving, isTrue);

      int pumps = 0;
      while (state.isMateSolving && pumps < 50) {
        await tester.pump(const Duration(milliseconds: 50));
        pumps++;
      }

      final proven = await solverFuture;
      await tester.pumpAndSettle();

      expect(proven, isTrue);
      expect(state.isMateSolving, isFalse);

      expect(find.text('Mate Search Complete'), findsOneWidget);
      expect(find.textContaining('Nodes explored:'), findsOneWidget);
      expect(find.textContaining('Time:'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Mate Search Complete'), findsNothing);

      final rootBfen = state.controller.game.bfen;
      expect(graph.v[rootBfen]?.effectiveEval?.result, equals(GameResult.whiteWins));
    });

    testWidgets('Multi-ply mate proves White top move and refutes all Black defenses', (WidgetTester tester) async {
      // White to move: 1. Qf7+ Kh8 2. Qxf8#
      // Position where Black has only one legal response Kh8
      const testFen = '5k2/5p2/5Q2/8/8/8/8/4K3 w - - 0 1';
      // Moves: 1. Qh8+ Ke7 2. Qe8# (or Qf7#)
      final chess = Chess();
      chess.load(testFen);
      final rootBfen = chess.bfen;

      // After 1. Qh8+ (White):
      chess.makeMove(chess.generateMoves().firstWhere((m) => '${m.fromAlgebraic}${m.toAlgebraic}' == 'f6h8'));
      final posAfterQh8 = chess.fen;
      // Black must play 1... Ke7:
      chess.makeMove(chess.generateMoves().firstWhere((m) => '${m.fromAlgebraic}${m.toAlgebraic}' == 'f8e7'));
      final posAfterKe7 = chess.fen;

      final engineService = _MockMateEngineService(
        responses: {
          testFen: const [
            EngineEvaluation(
              candidateMove: 'f6h8',
              centipawns: 500,
              depth: 16,
              fen: testFen,
            ),
          ],
          posAfterQh8: [
            EngineEvaluation(
              candidateMove: 'f8e7',
              centipawns: -500,
              depth: 16,
              fen: posAfterQh8,
            ),
          ],
          posAfterKe7: [
            EngineEvaluation(
              candidateMove: 'h8e8',
              mate: 1,
              depth: 16,
              fen: posAfterKe7,
            ),
          ],
        },
      );

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));
      state.controller.load(testFen);
      await tester.pumpAndSettle();

      final solverFuture = state.startMateSolver(maxDepth: 10);
      expect(state.isMateSolving, isTrue);

      int pumps = 0;
      while (state.isMateSolving && pumps < 60) {
        await tester.pump(const Duration(milliseconds: 50));
        pumps++;
      }

      final proven = await solverFuture;
      await tester.pumpAndSettle();

      expect(proven, isTrue);
      expect(state.isMateSolving, isFalse);

      expect(find.text('Mate Search Complete'), findsOneWidget);
      expect(find.textContaining('Nodes explored:'), findsOneWidget);
      expect(find.textContaining('Time:'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Mate Search Complete'), findsNothing);

      // Root position should be restored and solved as White win
      expect(state.controller.game.bfen, equals(rootBfen));
      expect(graph.v[rootBfen]?.effectiveEval?.result, equals(GameResult.whiteWins));
    });

    testWidgets('Depth cutoff returns false if mate is unproven within maxDepth', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final engineService = _MockMateEngineService(responses: {});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));
      final rootBfen = state.controller.game.bfen;

      // Set maxDepth to 1 ply
      final solverFuture = state.startMateSolver(maxDepth: 1);
      int pumps = 0;
      while (state.isMateSolving && pumps < 30) {
        await tester.pump(const Duration(milliseconds: 50));
        pumps++;
      }

      final proven = await solverFuture;
      await tester.pumpAndSettle();

      expect(proven, isFalse);
      expect(state.isMateSolving, isFalse);

      expect(find.text('Mate Search Failed'), findsOneWidget);
      expect(find.textContaining('Nodes explored:'), findsOneWidget);
      expect(find.textContaining('Time:'), findsOneWidget);

      // Verify jumping to failure point and returning to start
      final jumpFinder = find.widgetWithText(OutlinedButton, 'Jump to failure (1 ply)');
      expect(jumpFinder, findsOneWidget);

      await tester.tap(jumpFinder);
      await tester.pumpAndSettle();

      // Board has jumped to point of failure
      expect(state.controller.game.bfen, equals(state.mateSolverResult!.failureBfen));
      expect(find.widgetWithText(OutlinedButton, 'Return to start'), findsOneWidget);

      // Return to start
      await tester.tap(find.widgetWithText(OutlinedButton, 'Return to start'));
      await tester.pumpAndSettle();

      // Board has returned to root
      expect(state.controller.game.bfen, equals(rootBfen));
      expect(find.widgetWithText(OutlinedButton, 'Jump to failure (1 ply)'), findsOneWidget);

      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Mate Search Failed'), findsNothing);

      expect(state.controller.game.bfen, equals(rootBfen));
    });

    testWidgets('Stop button halts mate search and restores board to root', (WidgetTester tester) async {
      final engineService = _MockMateEngineService(responses: {});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));
      final rootBfen = state.controller.game.bfen;

      final solverFuture = state.startMateSolver(maxDepth: 20);
      expect(state.isMateSolving, isTrue);

      await tester.pump(const Duration(milliseconds: 50));

      // Stop button should be visible in the action buttons row
      final stopButtonFinder = find.widgetWithText(TextButton, 'stop mate');
      expect(stopButtonFinder, findsOneWidget);

      await tester.tap(stopButtonFinder);
      await tester.pump();

      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await solverFuture;
      await tester.pumpAndSettle();

      expect(state.isMateSolving, isFalse);
      expect(find.text('Mate Search Stopped'), findsOneWidget);
      expect(find.textContaining('Nodes explored:'), findsOneWidget);
      expect(find.textContaining('Time:'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Mate Search Stopped'), findsNothing);

      expect(state.controller.game.bfen, equals(rootBfen));
    });

    testWidgets('Progress card title refers to starting position with move number and san', (WidgetTester tester) async {
      final engineService = _MockMateEngineService(responses: {});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));
      state.controller.makeMoveWithNormalNotation('e4');
      state.controller.makeMoveWithNormalNotation('e5');
      state.controller.makeMoveWithNormalNotation('Nf3');
      await tester.pumpAndSettle();

      final solverFuture = state.startMateSolver(maxDepth: 1);
      expect(state.isMateSolving, isTrue);
      // The starting position was after White played 2. Nf3!
      // Since the evaluation favors White (+1.00), search searches for mate for White even though it is Black to move.
      expect(state.mateSolverTitle, equals('Finding mate for white after 2. Nf3'));

      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await solverFuture;
      await tester.pumpAndSettle();

      expect(find.text('Mate Search Failed'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.text('Mate Search Failed'), findsNothing);
    });

    testWidgets('Stacked minibars render progress for active defender plies', (WidgetTester tester) async {
      final engineService = _MockMateEngineService(responses: {});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));
      final solverFuture = state.startMateSolver(maxDepth: 4);

      // Pump a bit to enter the search tree
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));

      // If solver is active in defender plies
      if (state.mateSolverPlyProgress.isNotEmpty) {
        expect(find.textContaining('P1'), findsWidgets);
      }

      state.stopMateSolver();
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await solverFuture;
      await tester.pumpAndSettle();

      expect(state.mateSolverPlyProgress, isEmpty);
    });

    testWidgets('Mate solver determines attacking color from evaluation: favors White or Black regardless of turn', (WidgetTester tester) async {
      final engineService = _MockMateEngineService(responses: {});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: engineService,
        ),
      );
      await tester.pumpAndSettle();

      final state = tester.state<HomePageState>(find.byType(HomePage));

      // 1. Text field eval favoring White with Black to move
      state.controller.load('rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2');
      await tester.pumpAndSettle();
      state.evalController.text = '+2.50';
      expect(state.determineAttackingColor(), equals(PlayerColor.white));

      // 2. Text field eval favoring Black with White to move
      state.controller.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');
      await tester.pumpAndSettle();
      state.evalController.text = '-3.00';
      expect(state.determineAttackingColor(), equals(PlayerColor.black));

      // 3. Mate score favoring Black with White to move
      state.evalController.text = '-M2';
      expect(state.determineAttackingColor(), equals(PlayerColor.black));

      // 4. Mate score favoring White with Black to move
      state.controller.load('rnbqkbnr/pppp1ppp/8/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R b KQkq - 1 2');
      await tester.pumpAndSettle();
      state.evalController.text = '+M3';
      expect(state.determineAttackingColor(), equals(PlayerColor.white));

      // 5. Zero / neutral eval falls back to turn
      state.evalController.text = '0.00';
      expect(state.determineAttackingColor(), equals(PlayerColor.black));

      state.controller.load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');
      await tester.pumpAndSettle();
      state.evalController.text = '0.00';
      expect(state.determineAttackingColor(), equals(PlayerColor.white));
    });
  });
}
