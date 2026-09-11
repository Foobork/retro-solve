import 'dart:async';
import '../dataset_variant.dart';
import 'engine_cache.dart';
export 'engine_cache.dart';

/// Represents an engine evaluation produced by UCI engines (such as Fairy-Stockfish).
///
/// ### UCI Mate Score Convention
/// In UCI protocol, evaluations are always reported from the perspective of the **side to move**:
/// - **Forced Win in M moves (`score mate +M` where M > 0):**
///   The side to move has a forced win in M moves ($2M - 1$ plies).
///   Example: `mate +1` = 1 ply, `mate +2` = 3 plies, `mate +12` = 23 plies.
/// - **Forced Loss in M moves (`score mate -M` where M > 0):**
///   The side to move has a forced loss in M moves ($2M$ plies).
///   Example: `mate -1` = 2 plies, `mate -2` = 4 plies, `mate -12` = 24 plies.
/// - **Terminal position (`score mate 0`):**
///   Game is already over in the current position.
class EngineEvaluation {
  final int? centipawns;
  final int? mate;
  final int? depth;
  final String? candidateMove;
  final int? multipv;
  final String? fen;

  const EngineEvaluation({
    this.centipawns,
    this.mate,
    this.depth,
    this.candidateMove,
    this.multipv,
    this.fen,
  });

  /// Converts evaluation to White's perspective (positive values favor White, negative favor Black).
  ///
  /// When Black is to move, UCI scores are from Black's perspective, so we negate them:
  /// - Black winning (`mate +M`) becomes `mate -M` (favoring Black).
  /// - Black losing (`mate -M`) becomes `mate +M` (favoring White).
  EngineEvaluation asWhitePerspective({required bool whiteToMove}) {
    if (whiteToMove) return this;
    return EngineEvaluation(
      centipawns: centipawns != null ? -centipawns! : null,
      mate: mate != null ? -mate! : null,
      depth: depth,
      candidateMove: candidateMove,
      multipv: multipv,
      fen: fen,
    );
  }

  EngineEvaluation copyWithFen(String newFen) {
    return EngineEvaluation(
      centipawns: centipawns,
      mate: mate,
      depth: depth,
      candidateMove: candidateMove,
      multipv: multipv,
      fen: newFen,
    );
  }

  @override
  String toString() {
    String evalStr = 'unknown';
    if (mate != null) {
      evalStr = 'mate ${mate! > 0 ? '+' : ''}$mate';
    } else if (centipawns != null) {
      final pawns = centipawns! / 100.0;
      evalStr =
          pawns > 0 ? '+${pawns.toStringAsFixed(2)}' : pawns.toStringAsFixed(2);
    }

    final parts = <String>[];
    String prefix = multipv != null ? '#$multipv ' : '';
    parts.add('${prefix}Eval: $evalStr');
    if (depth != null) parts.add('Depth: $depth');
    if (candidateMove != null) parts.add('Move: $candidateMove');

    return parts.join('\n');
  }
}

final _depthRegex = RegExp(r'\bdepth (\d+)');
final _multipvRegex = RegExp(r'\bmultipv (\d+)');
final _scoreRegex = RegExp(r'\bscore (cp|mate) (-?\d+)');
final _pvRegex = RegExp(r'\bpv (\S+)');

EngineEvaluation? parseUciInfo(String line) {
  if (!line.startsWith('info ')) return null;

  final depthMatch = _depthRegex.firstMatch(line);
  final int? depth =
      depthMatch != null ? int.tryParse(depthMatch.group(1)!) : null;

  final multipvMatch = _multipvRegex.firstMatch(line);
  final int? multipv =
      multipvMatch != null ? int.tryParse(multipvMatch.group(1)!) : null;

  final scoreMatch = _scoreRegex.firstMatch(line);
  int? centipawns;
  int? mate;
  if (scoreMatch != null) {
    final kind = scoreMatch.group(1);
    final value = int.tryParse(scoreMatch.group(2) ?? '');
    if (kind == 'cp') {
      centipawns = value;
    } else {
      mate = value;
    }
  }

  final pvMatch = _pvRegex.firstMatch(line);
  final String? candidateMove = pvMatch?.group(1);

  if (centipawns == null &&
      mate == null &&
      depth == null &&
      candidateMove == null) {
    return null;
  }

  return EngineEvaluation(
    centipawns: centipawns,
    mate: mate,
    depth: depth,
    candidateMove: candidateMove,
    multipv: multipv,
  );
}

String uciVariantForDataset(DatasetVariant variant) {
  switch (variant) {
    case DatasetVariant.koth:
      return 'kingofthehill';
    case DatasetVariant.standard:
      return 'chess';
    case DatasetVariant.threeCheck:
      return '3check';
    case DatasetVariant.crazyhouse:
      return 'crazyhouse';
    case DatasetVariant.antichess:
      return 'antichess';
    case DatasetVariant.atomic:
      return 'atomic';
    case DatasetVariant.horde:
      return 'horde';
    case DatasetVariant.racingKings:
      return 'racingkings';
  }
}

abstract class EngineService {
  DatasetVariant get variant;
  bool get isNNUE;
  bool get isEngineAvailable;
  bool get isSearching;
  Stream<List<EngineEvaluation>> get evaluationStream;

  EngineCache get cache;

  List<EngineEvaluation>? getCachedEvaluation(String fen, {int minDepth = 16}) {
    return cache.get(variant, fen, minDepth: minDepth);
  }

  void setCachedEvaluation(String fen, List<EngineEvaluation> evals, {bool force = false}) {
    cache.put(variant, fen, evals, force: force);
  }

  void clearCache() {
    cache.clear();
  }

  int get cacheSize => cache.size;

  Future<void> start();
  Future<void> setVariant(DatasetVariant variant);
  Future<void> newGame();
  Future<void> startSearch(String fen);
  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16});
  Future<void> dispose();
}
