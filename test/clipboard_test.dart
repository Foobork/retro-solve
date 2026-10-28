import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  testWidgets('board updates and moves do not autocopy to clipboard, but Copy FEN and Move History copy correctly',
      (WidgetTester tester) async {
    final List<String> clipboardHistory = [];

    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall methodCall) async {
        if (methodCall.method == 'Clipboard.setData') {
          final text = (methodCall.arguments as Map)['text'] as String?;
          if (text != null) {
            clipboardHistory.add(text);
          }
          return null;
        } else if (methodCall.method == 'Clipboard.getData') {
          return <String, dynamic>{
            'text': clipboardHistory.isNotEmpty ? clipboardHistory.last : null,
          };
        }
        return null;
      },
    );

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.antichess,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify clipboard was NOT automatically populated on board load / update
    expect(clipboardHistory, isEmpty);

    // Make a move on the board
    final state = tester.state<HomePageState>(find.byType(HomePage));
    state.controller.makeMoveWithNormalNotation('e3');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));

    // Verify moving does NOT autocopy to clipboard
    expect(clipboardHistory, isEmpty);

    // 1. Test Copy FEN via More Actions menu
    final moreMenuFinder = find.byTooltip('More actions');
    expect(moreMenuFinder, findsOneWidget);
    await tester.tap(moreMenuFinder);
    await tester.pumpAndSettle();

    final copyFenItem = find.text('Copy FEN to clipboard');
    expect(copyFenItem, findsOneWidget);
    await tester.tap(copyFenItem, warnIfMissed: false);
    await tester.pumpAndSettle();

    final expectedFen = state.controller.game.fen;
    expect(clipboardHistory.length, equals(1));
    expect(clipboardHistory.last, equals(expectedFen));
    expect(find.text('FEN copied to clipboard'), findsOneWidget);

    // Dismiss snackbar
    ScaffoldMessenger.of(state.context).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    // 2. Test Copy Move History button on the widget
    final copyIconFinder = find.byTooltip('Copy move history');
    expect(copyIconFinder, findsOneWidget);
    await tester.tap(copyIconFinder);
    await tester.pumpAndSettle();

    expect(clipboardHistory.length, equals(2));
    expect(clipboardHistory.last, equals('1. e3'));
    expect(find.text('Move history copied to clipboard'), findsOneWidget);

    // Dismiss snackbar
    ScaffoldMessenger.of(state.context).hideCurrentSnackBar();
    await tester.pumpAndSettle();

    // 3. Make another move and test Copy Move History via More Actions menu
    state.controller.makeMoveWithNormalNotation('c5');
    await tester.pumpAndSettle();

    await tester.tap(moreMenuFinder);
    await tester.pumpAndSettle();

    final copyHistoryItem = find.text('Copy move history to clipboard');
    expect(copyHistoryItem, findsOneWidget);
    await tester.tap(copyHistoryItem, warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(clipboardHistory.length, equals(3));
    expect(clipboardHistory.last, equals('1. e3 c5'));
    expect(find.text('Move history copied to clipboard'), findsOneWidget);
  });
}
