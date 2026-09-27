import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
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

  group('Auto-solve after explore Switch Tests', () {
    test('AutosolveAfterExploreStore loads and saves preference', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await AutosolveAfterExploreStore.load(), isTrue);

      await AutosolveAfterExploreStore.save(false);
      expect(await AutosolveAfterExploreStore.load(), isFalse);

      await AutosolveAfterExploreStore.save(true);
      expect(await AutosolveAfterExploreStore.load(), isTrue);
    });

    testWidgets('Toggles auto-solve after explore via ellipsis more menu', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      SharedPreferences.setMockInitialValues({'autosolve_after_explore': true});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.antichess,
          engineService: _NoopEngineService(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      expect(state.autosolveAfterExplore, isTrue);

      // Open ellipsis more menu
      final moreMenuFinder = find.byTooltip('More actions');
      expect(moreMenuFinder, findsOneWidget);
      await tester.tap(moreMenuFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      // Scroll popup menu so the bottom items are fully visible
      await tester.drag(find.text('Interactive Backsolving'), const Offset(0, -200), warnIfMissed: false);
      await tester.pumpAndSettle();

      final autosolveMenuItem = find.text('Auto-solve after explore');
      expect(autosolveMenuItem, findsOneWidget);
      await tester.tap(autosolveMenuItem, warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(state.autosolveAfterExplore, isFalse);
      expect(await AutosolveAfterExploreStore.load(), isFalse);

      // Open ellipsis more menu again
      await tester.tap(moreMenuFinder);
      await tester.pumpAndSettle();

      await tester.drag(find.text('Interactive Backsolving'), const Offset(0, -200), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Tap to toggle back on
      await tester.tap(find.text('Auto-solve after explore'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(state.autosolveAfterExplore, isTrue);
      expect(await AutosolveAfterExploreStore.load(), isTrue);
    });

    testWidgets('setAutosolveAfterExploreForTesting updates state and store', (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({'autosolve_after_explore': true});

      await tester.pumpWidget(
        RetroSolve(
          initialVariant: DatasetVariant.antichess,
          engineService: _NoopEngineService(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      final state = tester.state<HomePageState>(find.byType(HomePage));
      expect(state.autosolveAfterExplore, isTrue);

      state.setAutosolveAfterExploreForTesting(false);
      await tester.pump();

      expect(state.autosolveAfterExplore, isFalse);
      expect(await AutosolveAfterExploreStore.load(), isFalse);

      state.setAutosolveAfterExploreForTesting(true);
      await tester.pump();

      expect(state.autosolveAfterExplore, isTrue);
      expect(await AutosolveAfterExploreStore.load(), isTrue);
    });
  });
}
