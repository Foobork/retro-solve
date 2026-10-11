import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/retro_solve.dart';

class _MockEngineService implements EngineService {
  _MockEngineService({required this.variant, EngineCache? cache})
      : cache = cache ?? EngineCache();

  @override
  final DatasetVariant variant;

  @override
  final EngineCache cache;

  @override
  bool get isNNUE => false;

  @override
  bool get isEngineAvailable => true;

  @override
  bool get isSearching => false;

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

void main() {
  group('game.move with move number prefixes', () {
    test('accepts moves with White and Black move numbers', () {
      final chess = Chess();
      expect(chess.move('1. Nf3'), isTrue);
      expect(chess.turn, equals(PlayerColor.black));
      expect(chess.move('1... f6'), isTrue);
      expect(chess.turn, equals(PlayerColor.white));
      expect(chess.move('2. d4'), isTrue);
      expect(chess.turn, equals(PlayerColor.black));
      expect(chess.move('2... d5'), isTrue);
      expect(chess.turn, equals(PlayerColor.white));
    });

    test('accepts moves without spaces after dots', () {
      final chess = Chess();
      expect(chess.move('1.e4'), isTrue);
      expect(chess.move('1...e5'), isTrue);
      expect(chess.move('2.Nf3'), isTrue);
    });
  });

  group('formatMoveWithNumber unit tests', () {
    testWidgets('formats moves correctly for White and Black across multiple turns',
        (WidgetTester tester) async {
      final mockService = _MockEngineService(variant: DatasetVariant.standard);
      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: mockService,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state(find.byType(HomePage)) as dynamic;

      // Initial position: White to move, move 1
      expect(state.formatMoveWithNumber('Nf3'), equals('1. Nf3'));
      expect(state.formatMoveWithNumber('e4'), equals('1. e4'));
      expect(state.formatMoveWithNumber('1. Nf3'), equals('1. Nf3'));
      expect(state.formatMoveWithNumber('—'), equals('—'));
      expect(state.formatMoveWithNumber(''), equals(''));

      // Make White move 1. Nf3
      state.controller.makeMoveWithNormalNotation('Nf3');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Black to move, move 1
      expect(state.controller.game.turn, equals(PlayerColor.black));
      expect(state.controller.game.moveNumber, equals(1));
      expect(state.formatMoveWithNumber('f6'), equals('1... f6'));
      expect(state.formatMoveWithNumber('d5'), equals('1... d5'));
      expect(state.formatMoveWithNumber('1... f6'), equals('1... f6'));

      // Make Black move 1... f6
      state.controller.makeMoveWithNormalNotation('f6');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // White to move, move 2
      expect(state.controller.game.turn, equals(PlayerColor.white));
      expect(state.controller.game.moveNumber, equals(2));
      expect(state.formatMoveWithNumber('d4'), equals('2. d4'));

      // Make White move 2. d4
      state.controller.makeMoveWithNormalNotation('d4');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Black to move, move 2
      expect(state.controller.game.turn, equals(PlayerColor.black));
      expect(state.controller.game.moveNumber, equals(2));
      expect(state.formatMoveWithNumber('d5'), equals('2... d5'));
    });
  });

  group('Movelist display in UI', () {
    testWidgets('displays move numbers in known movelist and clicking plays the move',
        (WidgetTester tester) async {
      final mockService = _MockEngineService(variant: DatasetVariant.standard);
      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: mockService,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state(find.byType(HomePage)) as dynamic;

      // Populate known move for root position (White move 1)
      final rootBfen = state.controller.game.bfen;
      graph.assign(rootBfen, const PositionEval(result: GameResult.draw, dtw: 0));
      // Give e4 a known child evaluation in graph
      const e4ChildFen = 'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq -';
      graph.assign(e4ChildFen, const PositionEval(result: GameResult.draw, dtw: 0));
      graph.addLink(rootBfen, e4ChildFen);

      // Force UI update
      state.controller.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify "1. e4" is rendered in the Known Moves table
      expect(find.text('1. e4'), findsOneWidget);

      // Tap on "1. e4" to play it
      await tester.tap(find.text('1. e4'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Now Black is to move (move 1)
      expect(state.controller.game.turn, equals(PlayerColor.black));
      expect(state.controller.game.moveNumber, equals(1));

      // Add child for Black's move e5
      final blackRootBfen = state.controller.game.bfen;
      const e5ChildFen = 'rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq -';
      graph.assign(e5ChildFen, const PositionEval(result: GameResult.draw, dtw: 0));
      graph.addLink(blackRootBfen, e5ChildFen);

      state.controller.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify "1... e5" is rendered in the Known Moves table
      expect(find.text('1... e5'), findsOneWidget);

      // Tap on "1... e5" to play it
      await tester.tap(find.text('1... e5'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Now White is to move (move 2)
      expect(state.controller.game.turn, equals(PlayerColor.white));
      expect(state.controller.game.moveNumber, equals(2));
    });

    testWidgets('displays move numbers in engine movelist and clicking plays the move',
        (WidgetTester tester) async {
      final mockService = _MockEngineService(variant: DatasetVariant.standard);
      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.standard,
          engineService: mockService,
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state(find.byType(HomePage)) as dynamic;
      final currentFen = state.controller.game.fen;

      // Emit engine candidate move for White: g1f3 (Nf3)
      mockService.emit([
        EngineEvaluation(
          candidateMove: 'g1f3',
          centipawns: 25,
          depth: 16,
          fen: currentFen,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify "1. Nf3" is displayed in the Engine movelist
      expect(find.text('1. Nf3'), findsOneWidget);

      // Tap "1. Nf3" from engine movelist
      await tester.tap(find.text('1. Nf3'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Board is now Black to move, move 1
      expect(state.controller.game.turn, equals(PlayerColor.black));
      expect(state.controller.game.moveNumber, equals(1));

      // Emit engine candidate move for Black: f7f6 (f6)
      final blackFen = state.controller.game.fen;
      mockService.emit([
        EngineEvaluation(
          candidateMove: 'f7f6',
          centipawns: -30,
          depth: 16,
          fen: blackFen,
        ),
      ]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify "1... f6" is displayed in the Engine movelist
      expect(find.text('1... f6'), findsOneWidget);

      // Tap "1... f6"
      await tester.tap(find.text('1... f6'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Board is now White to move, move 2
      expect(state.controller.game.turn, equals(PlayerColor.white));
      expect(state.controller.game.moveNumber, equals(2));
    });
  });
}
