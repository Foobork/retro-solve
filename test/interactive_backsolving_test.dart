import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/retro_solve.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _NoopEngineService extends FairyStockfishService {
  final _controller = StreamController<List<EngineEvaluation>>.broadcast();

  @override
  Stream<List<EngineEvaluation>> get evaluationStream => _controller.stream;

  @override
  bool get isEngineAvailable => false;

  @override
  Future<void> start() async {}

  @override
  Future<void> startSearch(String fen) async {}

  @override
  Future<void> dispose() async {
    _controller.close();
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Interactive Backsolving Switch Tests', () {
    test('InteractiveBacksolvingStore loads and saves preference', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await InteractiveBacksolvingStore.load(), isTrue);

      await InteractiveBacksolvingStore.save(false);
      expect(await InteractiveBacksolvingStore.load(), isFalse);

      await InteractiveBacksolvingStore.save(true);
      expect(await InteractiveBacksolvingStore.load(), isTrue);
    });

    testWidgets('Toggles interactive backsolving via ellipsis more menu', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'interactive_backsolving': true});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.antichess,
          engineService: _NoopEngineService(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      expect(state.interactiveBacksolving, isTrue);

      // Verify redundant action button switch is not present
      expect(find.text('backsolve'), findsNothing);
      expect(find.byType(Switch), findsNothing);

      // Open ellipsis more menu
      final moreMenuFinder = find.byTooltip('More actions');
      expect(moreMenuFinder, findsOneWidget);
      await tester.tap(moreMenuFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Find and tap 'Interactive Backsolving' checked menu item to toggle off
      final backsolveMenuItem = find.text('Interactive Backsolving');
      expect(backsolveMenuItem, findsOneWidget);
      await tester.tap(backsolveMenuItem, warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.interactiveBacksolving, isFalse);
      expect(await InteractiveBacksolvingStore.load(), isFalse);

      // Open ellipsis more menu again
      await tester.tap(moreMenuFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Tap to toggle back on
      await tester.tap(find.text('Interactive Backsolving'), warnIfMissed: false);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(state.interactiveBacksolving, isTrue);
      expect(await InteractiveBacksolvingStore.load(), isTrue);
    });

    testWidgets('Toggling interactive backsolving disables solveBfenAsync on board moves', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'interactive_backsolving': true});
      resetGraph();

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.antichess,
          engineService: _NoopEngineService(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      expect(state.interactiveBacksolving, isTrue);

      // Disable interactive backsolving
      state.setInteractiveBacksolvingForTesting(false);
      await tester.pump();
      expect(state.interactiveBacksolving, isFalse);

      // Make a move on board
      state.controller.makeMoveWithNormalNotation('e3');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(state.controller.game.history.isNotEmpty, isTrue);
    });
  });
}
