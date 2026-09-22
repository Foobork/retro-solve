import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../dataset_variant.dart';
import 'engine_service.dart';

/// Service that queries the Lichess Online Tablebase API (tablebase.lichess.ovh).
///
/// Supports:
/// - Antichess: endgames with 6 or fewer pieces.
/// - Atomic: endgames with 6 or fewer pieces.
/// - Standard Chess: endgames with 7 or fewer pieces.
class TablebaseService {
  TablebaseService({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    bool? enabled,
  })  : _client = client ?? http.Client(),
        _enabled = enabled;

  final http.Client _client;
  static const String defaultBaseUrl = 'https://tablebase.lichess.ovh';
  final String baseUrl;
  final bool? _enabled;

  /// Whether tablebase probing is enabled.
  bool get isEnabled => _enabled ?? Config.enableRemoteTablebase;

  /// Default singleton instance.
  static final TablebaseService instance = TablebaseService();

  /// Checks if tablebase lookup is supported for the given [variant] and [fen].
  static bool isSupported(DatasetVariant variant, String fen) {
    int maxPieces;
    switch (variant) {
      case DatasetVariant.antichess:
      case DatasetVariant.atomic:
        maxPieces = 6;
        break;
      case DatasetVariant.standard:
        maxPieces = 7;
        break;
      default:
        return false;
    }

    final tokens = fen.trim().split(RegExp(r'\s+'));
    if (tokens.isEmpty) return false;
    final piecePlacement = tokens.first;
    // Count pieces (characters a-z, A-Z) on the board
    final pieceCount =
        piecePlacement.replaceAll(RegExp(r'[^a-zA-Z]'), '').length;
    return pieceCount <= maxPieces;
  }

  /// Returns the API endpoint path component for [variant].
  static String? endpointForVariant(DatasetVariant variant) {
    switch (variant) {
      case DatasetVariant.antichess:
        return 'antichess';
      case DatasetVariant.atomic:
        return 'atomic';
      case DatasetVariant.standard:
        return 'standard';
      default:
        return null;
    }
  }

  /// Probes the Lichess Tablebase API for [fen] in [variant].
  ///
  /// Returns a list of [EngineEvaluation] for candidate moves (MultiPV 1..N),
  /// or `null` if unsupported, unknown, or if network probe fails.
  Future<List<EngineEvaluation>?> probe(
    DatasetVariant variant,
    String fen, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (!isEnabled || !isSupported(variant, fen)) return null;

    final endpoint = endpointForVariant(variant);
    if (endpoint == null) return null;

    final uri =
        Uri.parse('$baseUrl/$endpoint?fen=${Uri.encodeComponent(fen)}');

    try {
      final response = await _client.get(uri).timeout(timeout);
      if (response.statusCode != 200) return null;

      return parseTablebaseResponse(variant, fen, response.body);
    } catch (_) {
      // Gracefully fall back to local engine on error or timeout
      return null;
    }
  }

  /// Parses tablebase JSON body into a list of [EngineEvaluation] objects.
  static List<EngineEvaluation>? parseTablebaseResponse(
    DatasetVariant variant,
    String fen,
    String jsonBody,
  ) {
    try {
      final data = jsonDecode(jsonBody) as Map<String, dynamic>;
      final category = (data['category'] as String?)?.toLowerCase();
      if (category == null || category == 'unknown') return null;

      final posDtw = data['dtw'] as int?;
      final rawMoves = data['moves'] as List<dynamic>? ?? [];

      // If no moves are listed (e.g. terminal position)
      if (rawMoves.isEmpty) {
        int? mate;
        int? centipawns;
        final isCheckmate = data['checkmate'] == true;
        final isVariantWin = data['variant_win'] == true;
        final isVariantLoss = data['variant_loss'] == true;
        final isStalemate = data['stalemate'] == true;

        if (isCheckmate || isVariantWin || (isStalemate && category == 'win')) {
          mate = 0;
        } else if (isVariantLoss || (isStalemate && category == 'loss')) {
          mate = 0;
        } else if (posDtw != null) {
          final plies = posDtw.abs();
          if (category == 'win') {
            mate = plies == 0 ? 0 : (plies + 1) ~/ 2;
          } else if (category == 'loss') {
            mate = plies == 0 ? 0 : -((plies + 1) ~/ 2);
          } else {
            centipawns = 0;
          }
        } else {
          if (category == 'win') {
            centipawns = 20000;
          } else if (category == 'loss') {
            centipawns = -20000;
          } else if (category == 'draw') {
            centipawns = 0;
          }
        }

        return [
          EngineEvaluation(
            centipawns: centipawns,
            mate: mate,
            depth: 100,
            multipv: 1,
            fen: fen,
          )
        ];
      }

      final evals = <EngineEvaluation>[];
      final maxMoves = rawMoves.length > 5 ? 5 : rawMoves.length;

      for (var i = 0; i < maxMoves; i++) {
        final moveData = rawMoves[i] as Map<String, dynamic>;
        final moveUci = moveData['uci'] as String?;
        final moveCat = (moveData['category'] as String?)?.toLowerCase();
        final moveDtw = moveData['dtw'] as int?;
        final isCheckmate = moveData['checkmate'] == true;
        final isVariantWin = moveData['variant_win'] == true;
        final isVariantLoss = moveData['variant_loss'] == true;

        int? moveMate;
        int? moveCentipawns;

        // In Lichess Tablebase API, move['category'] is from opponent's perspective
        if (isCheckmate || isVariantWin) {
          moveMate = 1;
        } else if (isVariantLoss) {
          moveMate = -1;
        } else if (moveDtw != null) {
          final opponentPlies = moveDtw.abs();
          final plies = opponentPlies + 1;
          if (moveCat == 'loss') {
            // Opponent loses -> this move wins for side to move
            moveMate = (plies + 1) ~/ 2;
          } else if (moveCat == 'win') {
            // Opponent wins -> this move loses for side to move
            moveMate = -((plies + 1) ~/ 2);
          } else {
            moveCentipawns = 0;
          }
        } else {
          // DTW is null (e.g. 6-piece tablebases with DTZ only)
          if (moveCat == 'loss') {
            moveCentipawns = 20000;
          } else if (moveCat == 'win') {
            moveCentipawns = -20000;
          } else if (moveCat == 'draw' ||
              moveCat == 'cursed-win' ||
              moveCat == 'blessed-loss') {
            moveCentipawns = 0;
          } else {
            // Fallback to position category if move category is unstated
            if (category == 'win') {
              moveCentipawns = 20000;
            } else if (category == 'loss') {
              moveCentipawns = -20000;
            } else {
              moveCentipawns = 0;
            }
          }
        }

        evals.add(EngineEvaluation(
          centipawns: moveCentipawns,
          mate: moveMate,
          depth: 100,
          candidateMove: moveUci,
          multipv: i + 1,
          fen: fen,
        ));
      }

      return evals;
    } catch (_) {
      return null;
    }
  }
}
