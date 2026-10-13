import 'dart:async';
import 'package:flutter/material.dart';
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
  group('Known moves list capping and scrolling', () {
    testWidgets('shrinks to fit when 8 or fewer known moves', (WidgetTester tester) async {
      final mockService = _MockEngineService(variant: DatasetVariant.standard);
      await tester.pumpWidget(MaterialApp(
        home: HomePage(
          engineService: mockService,
          initialVariant: DatasetVariant.standard,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      final rootBfen = state.controller.game.bfen;
      graph.assign(rootBfen, const PositionEval(result: GameResult.draw, dtw: 0));

      // Add 4 moves
      final moves4 = ['e4', 'd4', 'c4', 'Nf3'];
      for (final m in moves4) {
        final g = state.controller.game.copy();
        g.move(m);
        graph.assign(g.bfen, const PositionEval(result: GameResult.draw, dtw: 0));
        graph.addLink(rootBfen, g.bfen);
      }

      state.controller.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final tableFinder = find.byType(Table).first;
      final tableSize = tester.getSize(tableFinder);

      // ConstrainedBox height shrinks to fit the exact 4 rows instead of expanding to 8
      final constrainedFinder = find.ancestor(of: tableFinder, matching: find.byType(ConstrainedBox)).first;
      final constrainedSize = tester.getSize(constrainedFinder);
      expect(constrainedSize.height, equals(tableSize.height));
    });

    testWidgets('caps visible known move list at 8 entries and allows scrolling remaining entries into view',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockService = _MockEngineService(variant: DatasetVariant.standard);
      await tester.pumpWidget(MaterialApp(
        home: HomePage(
          engineService: mockService,
          initialVariant: DatasetVariant.standard,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      final rootBfen = state.controller.game.bfen;
      graph.assign(rootBfen, const PositionEval(result: GameResult.draw, dtw: 0));

      // Add 10 moves: b3, c4, d3, d4, e3, e4, f4, g3, Nc3, Nf3
      final moves10 = ['e4', 'd4', 'c4', 'Nf3', 'Nc3', 'g3', 'b3', 'f4', 'e3', 'd3'];
      for (final m in moves10) {
        final g = state.controller.game.copy();
        g.move(m);
        graph.assign(g.bfen, const PositionEval(result: GameResult.draw, dtw: 0));
        graph.addLink(rootBfen, g.bfen);
      }

      state.controller.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final tableFinder = find.byType(Table).first;
      final tableSize = tester.getSize(tableFinder);
      final rowHeight = tableSize.height / 10;
      final constrainedFinder = find.ancestor(of: tableFinder, matching: find.byType(ConstrainedBox)).first;
      final constrainedSize = tester.getSize(constrainedFinder);
      expect(constrainedSize.height, equals(8 * rowHeight));

      // The 1st move (1. b3) is visible at the top
      expect(find.text('1. b3'), findsOneWidget);

      // The scroll controller starts at offset 0
      expect(state.knownMovesScrollController.offset, equals(0.0));

      // Scroll the moves list down to bring 10th move (1. Nf3) into view
      final movesScrollFinder = find.ancestor(of: tableFinder, matching: find.byType(SingleChildScrollView)).first;
      await tester.drag(movesScrollFinder, const Offset(0, -200), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.knownMovesScrollController.offset, greaterThan(0.0));
      expect(find.text('1. Nf3'), findsOneWidget);

      // Tapping on the scrolled-in move plays it
      await tester.tap(find.text('1. Nf3'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.controller.game.turn, equals(PlayerColor.black));
    });

    testWidgets('caps visible known move list at 8 entries in narrow layout', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final mockService = _MockEngineService(variant: DatasetVariant.standard);
      await tester.pumpWidget(MaterialApp(
        home: HomePage(
          engineService: mockService,
          initialVariant: DatasetVariant.standard,
        ),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      final rootBfen = state.controller.game.bfen;
      graph.assign(rootBfen, const PositionEval(result: GameResult.draw, dtw: 0));

      // Add 12 moves
      final moves12 = ['e4', 'd4', 'c4', 'Nf3', 'Nc3', 'g3', 'b3', 'f4', 'e3', 'd3', 'a3', 'h3'];
      for (final m in moves12) {
        final g = state.controller.game.copy();
        g.move(m);
        graph.assign(g.bfen, const PositionEval(result: GameResult.draw, dtw: 0));
        graph.addLink(rootBfen, g.bfen);
      }

      state.controller.notifyListeners();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final tableFinder = find.byType(Table).first;
      final tableSize = tester.getSize(tableFinder);
      final rowHeight = tableSize.height / 12;
      final constrainedFinder = find.ancestor(of: tableFinder, matching: find.byType(ConstrainedBox)).first;
      final constrainedSize = tester.getSize(constrainedFinder);
      expect(constrainedSize.height, equals(8 * rowHeight));
    });
  });
}
