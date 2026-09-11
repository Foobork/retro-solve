import 'dart:collection';
import '../dataset_variant.dart';
import 'engine_service.dart';

/// In-memory LRU cache for engine evaluations.
///
/// Evaluations are keyed canonically by `[DatasetVariant]` and board position
/// (stripping move counters so transpositions share cache hits).
class EngineCache {
  EngineCache({
    this.maxEntries = 50000,
    this.minCacheDepth = 16,
  });

  /// Maximum number of positions to keep in cache before evicting least-recently used.
  final int maxEntries;

  /// Minimum search depth required for an evaluation to be cached (unless mate is found).
  final int minCacheDepth;

  final LinkedHashMap<String, List<EngineEvaluation>> _cache =
      LinkedHashMap<String, List<EngineEvaluation>>();

  /// Returns the canonical cache key for a given [variant] and [fen].
  ///
  /// Strips the halfmove clock and fullmove number so transpositions share the same key,
  /// while preserving variant-specific state (like 3-check check counts).
  static String canonicalKey(DatasetVariant variant, String fen) {
    var tokens = fen.trim().split(RegExp(r'\s+'));
    if (tokens.length >= 6 &&
        int.tryParse(tokens[tokens.length - 1]) != null &&
        int.tryParse(tokens[tokens.length - 2]) != null) {
      tokens = tokens.sublist(0, tokens.length - 2);
    } else if (tokens.length == 5 &&
        int.tryParse(tokens.last) != null &&
        !tokens[4].contains('+')) {
      tokens = tokens.sublist(0, tokens.length - 1);
    }
    return '${variant.name}:${tokens.join(' ')}';
  }

  /// Validates whether [candidateMove] matches the side to move in [fen].
  ///
  /// Returns `true` if the move is consistent with the side to move in [fen],
  /// or if [candidateMove] is empty / not parseable.
  /// Returns `false` if the piece on the source square (or drop piece) belongs
  /// to the opposite color or if the source square is empty.
  static bool isMoveColorConsistentWithFen(String fen, String candidateMove) {
    final clean = candidateMove.trim().replaceAll('-', '').toLowerCase();
    if (clean.isEmpty || clean.length < 4) return true;

    final tokens = fen.trim().split(RegExp(r'\s+'));
    if (tokens.length < 2) return true;
    final turn = tokens[1].toLowerCase();
    if (turn != 'w' && turn != 'b') return true;

    // Check crazyhouse drops, e.g. P@e4 or p@e4
    final rawTrim = candidateMove.trim();
    if (rawTrim.length >= 3 && rawTrim[1] == '@') {
      final pieceChar = rawTrim[0];
      final isWhitePiece = pieceChar == pieceChar.toUpperCase() && pieceChar != pieceChar.toLowerCase();
      return turn == (isWhitePiece ? 'w' : 'b');
    }

    // Standard move: fromSquare is first 2 chars, e.g. 'e2'
    final fileChar = clean[0];
    final rankChar = clean[1];
    final file = fileChar.codeUnitAt(0) - 'a'.codeUnitAt(0); // 0..7
    final rank = int.tryParse(rankChar); // 1..8
    if (file < 0 || file > 7 || rank == null || rank < 1 || rank > 8) {
      return true;
    }

    // Parse the board rank from FEN
    final ranks = tokens[0].split('/');
    if (ranks.length != 8) return true;

    final fenRankIndex = 8 - rank; // 0 for rank 8, 7 for rank 1
    final rankStr = ranks[fenRankIndex];

    int col = 0;
    String? pieceAtFrom;
    for (int i = 0; i < rankStr.length; i++) {
      final c = rankStr[i];
      final digit = int.tryParse(c);
      if (digit != null) {
        col += digit;
      } else {
        if (col == file) {
          pieceAtFrom = c;
          break;
        }
        col++;
      }
      if (col > file) break;
    }

    if (pieceAtFrom == null) {
      // Source square is empty; a move cannot originate from an empty square.
      return false;
    }

    final isWhitePiece = pieceAtFrom == pieceAtFrom.toUpperCase() &&
        pieceAtFrom != pieceAtFrom.toLowerCase();
    return turn == (isWhitePiece ? 'w' : 'b');
  }

  /// Retrieves cached evaluations for [fen] under [variant].
  ///
  /// Returns `null` if the position is not cached or if the cached evaluation
  /// does not meet [minDepth] (and is not a forced mate).
  List<EngineEvaluation>? get(
    DatasetVariant variant,
    String fen, {
    int minDepth = 16,
  }) {
    final key = canonicalKey(variant, fen);
    final entry = _cache.remove(key);
    if (entry == null) return null;

    // Verify candidate moves match the side to move of fen; purge if corrupt
    for (final e in entry) {
      if (e.candidateMove != null &&
          !isMoveColorConsistentWithFen(fen, e.candidateMove!)) {
        return null;
      }
    }

    // Re-insert at the end to maintain LRU recency
    _cache[key] = entry;

    if (entry.isEmpty) return null;
    final best = entry.first;
    if (best.mate != null || (best.depth != null && best.depth! >= minDepth)) {
      return entry;
    }
    return null;
  }

  /// Stores [evals] for [fen] under [variant].
  ///
  /// Evaluations are only stored if they meet [minCacheDepth] or have a forced mate.
  /// Deeper or mate evaluations will not be overwritten by shallower ones.
  void put(DatasetVariant variant, String fen, List<EngineEvaluation> evals) {
    if (evals.isEmpty) return;

    // Reject evaluations whose candidate moves do not match the side to move of fen
    for (final e in evals) {
      if (e.candidateMove != null &&
          !isMoveColorConsistentWithFen(fen, e.candidateMove!)) {
        return;
      }
    }

    final best = evals.first;
    final depth = best.depth ?? 0;
    if (best.mate == null && depth < minCacheDepth) {
      return;
    }

    final key = canonicalKey(variant, fen);
    final existing = _cache[key];
    if (existing != null && existing.isNotEmpty) {
      final existingBest = existing.first;
      final existingDepth = existingBest.depth ?? 0;

      // Do not replace mate with non-mate
      if (existingBest.mate != null && best.mate == null) {
        return;
      }
      // Do not downgrade depth unless replacing non-mate with mate
      if (existingDepth > depth && (best.mate == null || existingBest.mate != null)) {
        return;
      }
    }

    _cache.remove(key);
    while (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = List.unmodifiable(evals);
  }

  /// Returns `true` if a valid evaluation meeting [minDepth] is cached for [fen].
  bool containsKey(
    DatasetVariant variant,
    String fen, {
    int minDepth = 16,
  }) {
    return get(variant, fen, minDepth: minDepth) != null;
  }

  /// Clears all cached evaluations.
  void clear() {
    _cache.clear();
  }

  /// Clears evaluations for a specific [variant].
  void clearVariant(DatasetVariant variant) {
    final prefix = '${variant.name}:';
    _cache.removeWhere((key, _) => key.startsWith(prefix));
  }

  /// Current number of cached positions.
  int get size => _cache.length;
}
