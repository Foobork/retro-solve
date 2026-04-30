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
  testWidgets('Do nothing', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    await tester.pumpWidget(
      RetroSolve(
        initialVariant: DatasetVariant.koth,
        engineService: _NoopEngineService(),
      ),
    );
  });
}
