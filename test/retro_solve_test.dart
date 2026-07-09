import 'package:retro_solve/retro_solve.dart';
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/engine/fairy_stockfish_service.dart';
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
}
