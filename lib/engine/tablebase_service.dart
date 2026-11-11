import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '../config.dart';
import '../dataset_variant.dart';
import 'engine_service.dart';
import 'tablebase_launcher.dart';

/// Service that queries the Lichess Online Tablebase API (tablebase.lichess.ovh)
/// or a local Syzygy/Antichess sidecar server.
///
/// Supports:
/// - Antichess: endgames with 6 or fewer pieces.
/// - Atomic: endgames with 6 or fewer pieces.
/// - Standard Chess: endgames with 7 or fewer pieces.
class TablebaseService {
  TablebaseService({
    http.Client? client,
    this.baseUrl = defaultBaseUrl,
    String? localUrl,
    bool? enabled,
    bool? localEnabled,
    bool? autoLaunch,
    String? clientId,
    TablebaseServerLauncher? launcher,
  })  : _client = client ?? http.Client(),
        localUrl = localUrl ?? defaultLocalUrl,
        _enabled = enabled,
        _localEnabled = localEnabled,
        _autoLaunch = autoLaunch,
        _isCustomClient = client != null,
        clientId = clientId ?? _generateClientId(),
        _launcher = launcher ?? TablebaseServerLauncher();

  final http.Client _client;
  final bool _isCustomClient;
  static const String defaultBaseUrl = 'https://tablebase.lichess.ovh';
  static const String defaultLocalUrl = 'http://127.0.0.1:8080';
  final String baseUrl;
  final String localUrl;
  final bool? _enabled;
  final bool? _localEnabled;
  final bool? _autoLaunch;
  final String clientId;
  final TablebaseServerLauncher _launcher;

  Timer? _heartbeatTimer;
  bool _isRegistered = false;
  Future<bool>? _serverCheckFuture;
  DateTime? _lastLaunchAttempt;
  static const Duration defaultHeartbeatInterval = Duration(seconds: 5);

  /// Whether this client instance is registered with the tablebase sidecar server.
  bool get isRegistered => _isRegistered;

  /// Whether auto-launching the local tablebase sidecar server is enabled.
  bool get isAutoLaunchEnabled =>
      _autoLaunch ??
      (_isCustomClient ? false : Config.autoLaunchTablebaseServer);

  static int _clientCounter = 0;
  static String _generateClientId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final counter = ++_clientCounter;
    final rand = (now ^ (counter << 16)) & 0xFFFFFF;
    return 'retrosolve_${now}_$rand';
  }

  /// Whether remote tablebase probing is enabled.
  bool get isEnabled => _enabled ?? Config.enableRemoteTablebase;

  /// Whether local tablebase probing is enabled.
  bool get isLocalEnabled =>
      _localEnabled ?? (_isCustomClient ? false : Config.enableLocalTablebase);

  /// Whether either local or remote tablebase probing is enabled.
  bool get isAnyEnabled => isLocalEnabled || isEnabled;

  /// Default singleton instance.
  static final TablebaseService instance = TablebaseService();

  /// Ensures the local tablebase sidecar server is running, healthy, and registered.
  ///
  /// If the server is not reachable and auto-launch is enabled, launches the server
  /// process in the background, waits until healthy, and registers this client.
  Future<bool> ensureServerRunning({
    Duration timeout = const Duration(seconds: 10),
    bool forceCheck = false,
  }) async {
    if (!isLocalEnabled) return false;
    if (!forceCheck && _isRegistered && _heartbeatTimer != null) {
      return true;
    }
    if (_serverCheckFuture != null) {
      return _serverCheckFuture!;
    }

    final completer = Completer<bool>();
    _serverCheckFuture = completer.future;

    try {
      final success = await _ensureServerRunningInternal(timeout: timeout);
      completer.complete(success);
      return success;
    } catch (_) {
      completer.complete(false);
      return false;
    } finally {
      _serverCheckFuture = null;
    }
  }

  Future<bool> _ensureServerRunningInternal({
    required Duration timeout,
  }) async {
    final uri = Uri.parse(localUrl);

    // 1. Check if server is already responding
    if (await checkHealth(timeout: const Duration(milliseconds: 600))) {
      await registerClient();
      startHeartbeat();
      return true;
    }

    // 2. If not alive, check if auto-launch is enabled
    if (!isAutoLaunchEnabled) {
      return false;
    }

    // Cooldown check between process spawn attempts to avoid spamming
    final now = DateTime.now();
    if (_lastLaunchAttempt != null &&
        now.difference(_lastLaunchAttempt!) < const Duration(seconds: 15)) {
      return false;
    }
    _lastLaunchAttempt = now;

    // Launch server process
    final launched = await _launcher.launchServer(
      port: uri.hasPort ? uri.port : 8080,
      host: uri.host.isNotEmpty ? uri.host : '127.0.0.1',
    );
    if (!launched) {
      return false;
    }

    // 3. Poll for readiness
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (await checkHealth(timeout: const Duration(milliseconds: 400))) {
        await registerClient();
        startHeartbeat();
        return true;
      }
    }

    return false;
  }

  /// Checks the /health endpoint of the local tablebase server.
  Future<bool> checkHealth({
    Duration timeout = const Duration(milliseconds: 600),
  }) async {
    try {
      final healthUri = Uri.parse('$localUrl/health');
      final response = await _client.get(healthUri).timeout(timeout);
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Registers this client session with the local tablebase server.
  Future<bool> registerClient({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final regUri = Uri.parse(
          '$localUrl/client/register?client_id=${Uri.encodeComponent(clientId)}');
      final response = await _client.post(regUri).timeout(timeout);
      if (response.statusCode == 200) {
        _isRegistered = true;
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Starts the periodic heartbeat timer.
  void startHeartbeat({Duration interval = defaultHeartbeatInterval}) {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(interval, (_) async {
      await sendHeartbeat();
    });
  }

  /// Sends a heartbeat to the local tablebase server to renew the client lease.
  Future<bool> sendHeartbeat({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      final hbUri = Uri.parse(
          '$localUrl/client/heartbeat?client_id=${Uri.encodeComponent(clientId)}');
      final response = await _client.post(hbUri).timeout(timeout);
      if (response.statusCode == 200) {
        _isRegistered = true;
        return true;
      } else {
        _isRegistered = false;
        return false;
      }
    } catch (_) {
      _isRegistered = false;
      return false;
    }
  }

  /// Unregisters this client session from the tablebase server and stops heartbeats.
  Future<void> unregisterClient({
    Duration timeout = const Duration(milliseconds: 800),
  }) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (!_isRegistered) return;
    _isRegistered = false;
    try {
      final unregUri = Uri.parse(
          '$localUrl/client/unregister?client_id=${Uri.encodeComponent(clientId)}');
      await _client.post(unregUri).timeout(timeout);
    } catch (_) {}
  }

  /// Disposes this service, cancelling heartbeats and unregistering the client session.
  void dispose() {
    unregisterClient();
    if (!_isCustomClient) {
      _client.close();
    }
  }

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

  /// Probes the local tablebase sidecar server for [fen] in [variant].
  ///
  /// Strictly queries the local sidecar without touching external networks.
  Future<List<EngineEvaluation>?> probeLocal(
    DatasetVariant variant,
    String fen, {
    Duration timeout = const Duration(milliseconds: 2000),
  }) async {
    if (!isLocalEnabled || !isSupported(variant, fen)) return null;

    if (!_isRegistered && isAutoLaunchEnabled) {
      unawaited(ensureServerRunning());
    }

    final endpoint = endpointForVariant(variant);
    if (endpoint == null) return null;

    try {
      final localUri =
          Uri.parse('$localUrl/$endpoint?fen=${Uri.encodeComponent(fen)}');
      final response = await _client.get(localUri).timeout(timeout);
      if (response.statusCode != 200) return null;

      final evals = parseTablebaseResponse(variant, fen, response.body);
      if (evals != null && evals.isNotEmpty) {
        // ignore: avoid_print
        print('[tablebase] Local sidecar ($variant): ${evals.first.candidateMove ?? "pos"} (dtw=${evals.first.dtw}, mate=${evals.first.mate})');
        return evals;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Probes the remote Lichess Tablebase API for [fen] in [variant].
  ///
  /// Queries tablebase.lichess.ovh. Avoid calling in tight exploration loops
  /// to prevent HTTP 429 rate limiting.
  Future<List<EngineEvaluation>?> probeRemote(
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
      return null;
    }
  }

  /// Probes tablebase for [fen] in [variant].
  ///
  /// When [isLocalEnabled] is true, queries ONLY the local tablebase sidecar.
  /// Never falls back to remote Lichess to prevent API throttling and rate-limiting.
  ///
  /// Remote Lichess is only queried if [isLocalEnabled] is false and [isEnabled] is true.
  Future<List<EngineEvaluation>?> probe(
    DatasetVariant variant,
    String fen, {
    Duration timeout = const Duration(seconds: 3),
    Duration localTimeout = const Duration(milliseconds: 2000),
  }) async {
    if (!isSupported(variant, fen)) return null;
    if (_enabled == false && _localEnabled != true) return null;

    // When local tablebase is enabled, stay 100% offline to prevent Lichess throttling
    if (isLocalEnabled) {
      return probeLocal(variant, fen, timeout: localTimeout);
    }

    if (isEnabled) {
      return probeRemote(variant, fen, timeout: timeout);
    }

    return null;
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

      final posDtw = (data['dtw'] ?? data['dtm']) as int?;
      final rawMoves = data['moves'] as List<dynamic>? ?? [];

      // If no moves are listed (e.g. terminal position)
      if (rawMoves.isEmpty) {
        int? mate;
        int? centipawns;
        int? dtwPlies;
        final isCheckmate = data['checkmate'] == true;
        final isVariantWin = data['variant_win'] == true;
        final isVariantLoss = data['variant_loss'] == true;
        final isStalemate = data['stalemate'] == true;

        if (isCheckmate || isVariantWin || (isStalemate && category == 'win')) {
          mate = 0;
          dtwPlies = 0;
        } else if (isVariantLoss || (isStalemate && category == 'loss')) {
          mate = 0;
          dtwPlies = 0;
        } else if (posDtw != null) {
          final plies = posDtw.abs();
          dtwPlies = plies;
          if (category == 'win') {
            mate = plies == 0 ? 0 : (plies + 1) ~/ 2;
          } else if (category == 'loss') {
            mate = plies == 0 ? 0 : -((plies + 1) ~/ 2);
          } else {
            centipawns = 0;
            dtwPlies = null;
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

        if (dtwPlies == null && !isCheckmate && !isVariantWin && !isVariantLoss && centipawns == null) {
          return null;
        }

        return [
          EngineEvaluation(
            centipawns: centipawns,
            mate: mate,
            dtw: dtwPlies,
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
        final moveDtw = (moveData['dtw'] ?? moveData['dtm']) as int?;
        final isCheckmate = moveData['checkmate'] == true;
        final isVariantWin = moveData['variant_win'] == true;
        final isVariantLoss = moveData['variant_loss'] == true;

        int? moveMate;
        int? moveCentipawns;
        int? moveDtwPlies;

        // In Lichess Tablebase API, move['category'] is from opponent's perspective
        if (isCheckmate || isVariantWin) {
          moveMate = 1;
          moveDtwPlies = 1;
        } else if (isVariantLoss) {
          moveMate = -1;
          moveDtwPlies = 1;
        } else if (moveDtw != null) {
          final opponentPlies = moveDtw.abs();
          final plies = opponentPlies + 1;
          moveDtwPlies = plies;
          if (moveCat == 'loss') {
            // Opponent loses -> this move wins for side to move
            moveMate = (plies + 1) ~/ 2;
          } else if (moveCat == 'win') {
            // Opponent wins -> this move loses for side to move
            moveMate = -((plies + 1) ~/ 2);
          } else {
            moveCentipawns = 0;
            moveDtwPlies = null;
          }
        } else {
          // DTW is null (e.g. 7-piece tablebases with DTZ only)
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
          dtw: moveDtwPlies,
          depth: 100,
          candidateMove: moveUci,
          multipv: i + 1,
          fen: fen,
        ));
      }

      if (evals.isEmpty) {
        return null;
      }

      return evals;
    } catch (_) {
      return null;
    }
  }
}
