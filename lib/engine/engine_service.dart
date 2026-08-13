import 'dart:async';
import '../dataset_variant.dart';

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

  /// UCI scores are from the side to move. Flip sign when Black is to move so
  /// values represent White's perspective (positive favors White).
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
  Stream<List<EngineEvaluation>> get evaluationStream;

  Future<void> start();
  Future<void> setVariant(DatasetVariant variant);
  Future<void> newGame();
  Future<void> startSearch(String fen);
  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16});
  Future<void> dispose();
}
