import 'dart:async';
import '../dataset_variant.dart';
import 'engine_service.dart';

class FairyStockfishService implements EngineService {
  FairyStockfishService({
    String binaryName = 'fairy-stockfish_x86-64-modern.exe',
    int searchDepth = 16,
    Duration commandTimeout = const Duration(seconds: 5),
    DatasetVariant initialVariant = DatasetVariant.koth,
    EngineCache? cache,
  })  : _variant = initialVariant,
        cache = cache ?? EngineCache();

  @override
  final EngineCache cache;

  @override
  List<EngineEvaluation>? getCachedEvaluation(String fen, {int minDepth = 16}) =>
      cache.get(_variant, fen, minDepth: minDepth);

  @override
  void setCachedEvaluation(String fen, List<EngineEvaluation> evals) =>
      cache.put(_variant, fen, evals);

  @override
  void clearCache() => cache.clear();

  @override
  int get cacheSize => cache.size;

  DatasetVariant _variant;

  @override
  DatasetVariant get variant => _variant;

  @override
  bool get isNNUE => false;

  @override
  bool get isEngineAvailable => false;

  @override
  bool get isSearching => false;

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
