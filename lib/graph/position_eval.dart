/// Represents the game-theoretic outcome of a position from White's perspective.
///
/// Integer values correspond to standard game theory / minimax conventions:
/// - `1`: White wins (+1)
/// - `-1`: Black wins (-1)
/// - `0`: Draw (0)
enum GameResult {
  whiteWins(1),
  draw(0),
  blackWins(-1);

  final int value;
  const GameResult(this.value);

  static GameResult? fromInt(int? val) {
    if (val == null) return null;
    switch (val) {
      case 1:
        return GameResult.whiteWins;
      case -1:
        return GameResult.blackWins;
      case 0:
        return GameResult.draw;
      default:
        return null;
    }
  }

  bool isWinFor(bool whiteToMove) =>
      whiteToMove ? this == GameResult.whiteWins : this == GameResult.blackWins;

  bool isLossFor(bool whiteToMove) =>
      whiteToMove ? this == GameResult.blackWins : this == GameResult.whiteWins;
}

/// Encapsulates all evaluation dimensions for a chess / variant position:
/// - [result]: Definite game-theoretic outcome ([GameResult.whiteWins], [GameResult.blackWins], [GameResult.draw]).
/// - [dtw]: Exact Distance to Win in plies (terminal mate distance / DTM).
/// - [cp]: Heuristic evaluation in centipawns from White's perspective.
class PositionEval {
  final GameResult? result;
  final int? dtw;
  final int? cp;

  const PositionEval({
    this.result,
    this.dtw,
    this.cp,
  });

  bool get isDecisive => result != null;
  bool get isMate => dtw != null;

  /// Inverts the evaluation to the opposite perspective if needed.
  PositionEval get inverted => PositionEval(
        result: result == GameResult.whiteWins
            ? GameResult.blackWins
            : (result == GameResult.blackWins ? GameResult.whiteWins : result),
        dtw: dtw,
        cp: cp != null ? -cp! : null,
      );

  /// Converts this structured evaluation to a legacy floating-point score,
  /// compatible with legacy algorithms expecting mate scores around +/-1000.
  double? toLegacyScore() {
    if (result == GameResult.whiteWins) {
      return dtw != null ? (1000.0 - dtw!) : 950.0;
    } else if (result == GameResult.blackWins) {
      return dtw != null ? (-1000.0 + dtw!) : -950.0;
    } else if (result == GameResult.draw) {
      return 0.0;
    } else if (cp != null) {
      return cp! / 100.0;
    }
    return null;
  }

  /// Reconstructs a structured [PositionEval] from a legacy floating-point score.
  static PositionEval? fromLegacyScore(double? score) {
    if (score == null) return null;
    const double mateThreshold = 200.0;
    if (score.abs() >= mateThreshold) {
      if (score.abs() == 950.0 || (score.abs() >= 940.0 && score.abs() < 960.0)) {
        return PositionEval(
          result: score > 0 ? GameResult.whiteWins : GameResult.blackWins,
        );
      }
      final plies = (1000.0 - score.abs()).round();
      return PositionEval(
        result: score > 0 ? GameResult.whiteWins : GameResult.blackWins,
        dtw: plies,
      );
    } else if (score == 0.0) {
      return const PositionEval(cp: 0);
    } else {
      return PositionEval(cp: (score * 100).round());
    }
  }

  /// Formats the evaluation string for UI display (from White's perspective).
  String format({bool isMove = false}) {
    if (result == GameResult.draw) return '0.00';

    if (dtw != null) {
      final sign = result == GameResult.whiteWins ? '+' : '-';
      final int moves;
      if (isMove) {
        final totalPlies = 1 + dtw!;
        moves = (totalPlies + 1) ~/ 2;
      } else {
        moves = dtw == 0 ? 0 : (dtw! + 1) ~/ 2;
      }
      return '$sign' 'M$moves';
    }

    if (result != null) {
      final sign = result == GameResult.whiteWins ? '+' : '-';
      return '$sign' 'Mate';
    }

    if (cp != null) {
      final pawns = cp! / 100.0;
      return pawns > 0 ? '+${pawns.toStringAsFixed(2)}' : pawns.toStringAsFixed(2);
    }

    return '—';
  }

  /// Compares two candidate evaluations from the perspective of [whiteToMove].
  ///
  /// Returns a negative integer if [a] is preferred over [b],
  /// a positive integer if [b] is preferred over [a],
  /// or zero if they are equally preferable.
  static int compare(PositionEval? a, PositionEval? b, bool whiteToMove) {
    if (a == null && b == null) return 0;
    if (a == null) return 1; // rated move is preferred over unrated
    if (b == null) return -1;

    final targetWin = whiteToMove ? GameResult.whiteWins : GameResult.blackWins;
    final targetLoss = whiteToMove ? GameResult.blackWins : GameResult.whiteWins;

    final aWins = a.result == targetWin;
    final bWins = b.result == targetWin;
    if (aWins != bWins) {
      return aWins ? -1 : 1;
    }

    // Both are winning for the active side
    if (aWins && bWins) {
      // Immediate terminal checkmate / variant win in 1-2 plies ranks highest
      final aImmediate = a.dtw != null && a.dtw! <= 2;
      final bImmediate = b.dtw != null && b.dtw! <= 2;
      if (aImmediate != bImmediate) {
        return aImmediate ? -1 : 1;
      }

      // If both have exact DTW, prefer the shorter mate distance
      if (a.dtw != null && b.dtw != null) {
        final cmp = a.dtw!.compareTo(b.dtw!);
        if (cmp != 0) return cmp;
      } else if (a.dtw != null && b.dtw == null) {
        // Known exact mate is preferred over unknown mate distance
        return -1;
      } else if (a.dtw == null && b.dtw != null) {
        return 1;
      }

      // Tie-breaker: heuristic centipawns if available
      if (a.cp != null && b.cp != null) {
        return whiteToMove ? b.cp!.compareTo(a.cp!) : a.cp!.compareTo(b.cp!);
      }
      return 0;
    }

    final aLoses = a.result == targetLoss;
    final bLoses = b.result == targetLoss;
    if (aLoses != bLoses) {
      return aLoses ? 1 : -1; // Losing is worse than non-losing
    }

    // Both are losing for the active side: resist as long as possible
    if (aLoses && bLoses) {
      // Prefer longer DTW to delay loss
      if (a.dtw != null && b.dtw != null) {
        final cmp = b.dtw!.compareTo(a.dtw!); // larger dtw preferred
        if (cmp != 0) return cmp;
      } else if (a.dtw != null && b.dtw == null) {
        return 1;
      } else if (a.dtw == null && b.dtw != null) {
        return -1;
      }

      if (a.cp != null && b.cp != null) {
        return whiteToMove ? b.cp!.compareTo(a.cp!) : a.cp!.compareTo(b.cp!);
      }
      return 0;
    }

    // Draws
    final aDraw = a.result == GameResult.draw || (a.result == null && a.cp == 0);
    final bDraw = b.result == GameResult.draw || (b.result == null && b.cp == 0);

    // Positive heuristic scores
    final aPos = !aDraw && a.cp != null && (whiteToMove ? a.cp! > 0 : a.cp! < 0);
    final bPos = !bDraw && b.cp != null && (whiteToMove ? b.cp! > 0 : b.cp! < 0);
    if (aPos != bPos) {
      return aPos ? -1 : 1;
    }

    // If both have positive heuristic scores
    if (aPos && bPos) {
      return whiteToMove ? b.cp!.compareTo(a.cp!) : a.cp!.compareTo(b.cp!);
    }

    if (aDraw != bDraw) {
      return aDraw ? -1 : 1;
    }
    if (aDraw && bDraw) {
      return 0;
    }

    // Negative heuristic scores
    if (a.cp != null && b.cp != null) {
      return whiteToMove ? b.cp!.compareTo(a.cp!) : a.cp!.compareTo(b.cp!);
    }

    return 0;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PositionEval &&
          runtimeType == other.runtimeType &&
          result == other.result &&
          dtw == other.dtw &&
          cp == other.cp;

  @override
  int get hashCode => Object.hash(result, dtw, cp);

  @override
  String toString() =>
      'PositionEval(result: $result, dtw: $dtw, cp: $cp)';
}