import 'dart:async';
import '../dataset_variant.dart';
import 'engine_service.dart';

class FairyStockfishService implements EngineService {
  FairyStockfishService({
    String binaryName = 'fairy-stockfish_x86-64-modern.exe',
    int searchDepth = 12,
    Duration commandTimeout = const Duration(seconds: 5),
    DatasetVariant initialVariant = DatasetVariant.koth,
  }) : _variant = initialVariant;

  DatasetVariant _variant;

  @override
  DatasetVariant get variant => _variant;

  @override
  bool get isNNUE => false;

  @override
  bool get isEngineAvailable => false;

  final StreamController<List<EngineEvaluation>> _evaluationController =
      StreamController<List<EngineEvaluation>>.broadcast();

  @override
  Stream<List<EngineEvaluation>> get evaluationStream =>
      _evaluationController.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> setVariant(DatasetVariant variant) async {
    _variant = variant;
  }

  @override
  Future<void> newGame() async {}

  @override
  Future<void> startSearch(String fen) async {}

  @override
  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16}) async {
    return null;
  }

  @override
  Future<void> dispose() async {
    await _evaluationController.close();
  }
}
