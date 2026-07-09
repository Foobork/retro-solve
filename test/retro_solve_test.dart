import 'package:flutter/material.dart';
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
    final vertex = graph.addVertex(startBfen);
    vertex.inDatabase = true;

    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.standard,
        engineService: _NoopEngineService(),
      ),
    );
    await tester.pumpAndSettle();
    
    // Set a computed mate in 5 moves (+990.0)
    vertex.computed = 990.0;
    
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
    expect(vertex.assigned, equals(994.0));
    expect(find.text('+M3'), findsOneWidget);
  });
}
