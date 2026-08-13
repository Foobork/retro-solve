// ignore_for_file: avoid_print, avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:html' as html;
import '../dataset_variant.dart';
import 'engine_service.dart';

class FairyStockfishService implements EngineService {
  FairyStockfishService({
    this.binaryName = 'fairy_stockfish_worker.js',
    this.searchDepth = 12,
    this.commandTimeout = const Duration(seconds: 10),
    DatasetVariant initialVariant = DatasetVariant.koth,
  }) : _variant = initialVariant;

  final String binaryName;
  final int searchDepth;
  final Duration commandTimeout;

  DatasetVariant _variant;

  @override
  DatasetVariant get variant => _variant;

  @override
  bool get isNNUE => false;

  html.Worker? _worker;
  StreamSubscription? _workerSubscription;
  StreamSubscription? _workerErrorSubscription;
  final StreamController<String> _stdoutLines =
      StreamController<String>.broadcast();
  final StreamController<List<EngineEvaluation>> _evaluationController =
      StreamController<List<EngineEvaluation>>.broadcast();

  @override
  Stream<List<EngineEvaluation>> get evaluationStream =>
      _evaluationController.stream;

  final List<EngineEvaluation> _currentEvals = [];
  String _activeFen = "";
  bool _isStarted = false;
  bool _waitingForReadyOk = false;
  Future<void> _evalQueue = Future<void>.value();

  @override
  bool get isEngineAvailable => _isStarted && _worker != null;

  @override
  Future<void> start() async {
    if (_isStarted && _worker != null) return;
    try {
      print('[engine-web] Launching Web Worker $binaryName ...');
      _worker = html.Worker(binaryName);
      _workerErrorSubscription = _worker!.onError.listen((err) {
        if (err is html.ErrorEvent) {
          print('[engine-web] Worker onerror: "${err.message}" at ${err.filename}:${err.lineno}:${err.colno}');
        } else {
          print('[engine-web] Worker onerror event: $err');
        }
      });
      _workerSubscription = _worker!.onMessage.listen((html.MessageEvent event) {
        final line = event.data?.toString() ?? '';
        if (line.startsWith('WORKER_')) {
          print('[engine-web-worker-log] $line');
        }
        _stdoutLines.add(line);
        if (line.trim() == 'readyok') {
          _waitingForReadyOk = false;
        }
        final parsedInfo = parseUciInfo(line);
        if (!_waitingForReadyOk &&
            parsedInfo != null &&
            (parsedInfo.centipawns != null || parsedInfo.mate != null)) {
          final idx = parsedInfo.multipv ?? 1;
          while (_currentEvals.length < idx) {
            _currentEvals.add(const EngineEvaluation());
          }
          final existing = _currentEvals[idx - 1];
          _currentEvals[idx - 1] = EngineEvaluation(
            centipawns: parsedInfo.centipawns,
            mate: parsedInfo.mate,
            depth: parsedInfo.depth ?? existing.depth,
            candidateMove: parsedInfo.candidateMove ?? existing.candidateMove,
            multipv: parsedInfo.multipv ?? existing.multipv,
            fen: _activeFen,
          );
          _evaluationController.add(List.from(_currentEvals));
        }
      });

      _writeLine('uci');
      await _waitForLine('uciok');
      _writeLine('setoption name UCI_Variant value ${uciVariantForDataset(_variant)}');
      _writeLine('isready');
      await _waitForLine('readyok');
      _isStarted = true;
      print('[engine-web] Fairy-Stockfish WASM Worker ready for ${uciVariantForDataset(_variant)}');

      if (_activeFen.isNotEmpty) {
        startSearch(_activeFen);
      }
    } catch (e) {
      print('[engine-web] Failed to initialize Fairy-Stockfish WASM worker: $e');
    }
  }

  @override
  Future<void> setVariant(DatasetVariant variant) async {
    if (_variant == variant) return;
    _variant = variant;
    if (_isStarted && _worker != null) {
      _writeLine('setoption name UCI_Variant value ${uciVariantForDataset(_variant)}');
      _writeLine('isready');
      await _waitForLine('readyok');
    }
  }

  @override
  Future<void> newGame() async {
    if (!_isStarted || _worker == null) return;
    _writeLine('stop');
    _writeLine('ucinewgame');
    _writeLine('isready');
    await _waitForLine('readyok');
  }

  @override
  Future<void> startSearch(String fen) async {
    _evalQueue = _evalQueue.then((_) => _startSearchImpl(fen));
  }

  Future<void> _startSearchImpl(String fen) async {
    if (!_isStarted || _worker == null) {
      await start();
      if (!_isStarted || _worker == null) return;
    }
    try {
      _activeFen = fen;
      _currentEvals.clear();
      _evaluationController.add([]);
      _waitingForReadyOk = true;
      _writeLine('stop');
      _writeLine('isready');
      await _waitForLine('readyok');
      _writeLine('setoption name MultiPV value 5');
      _writeLine('position fen $fen');
      _writeLine('go depth 16');
    } catch (e) {
      print('[engine-web] startSearch error: $e');
    }
  }

  @override
  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16}) async {
    if (!_isStarted || _worker == null) await start();
    if (!_isStarted || _worker == null) return null;

    _waitingForReadyOk = true;
    _writeLine('stop');
    _writeLine('isready');
    await _waitForLine('readyok');

    _currentEvals.clear();
    _writeLine('setoption name MultiPV value 1');
    _activeFen = fen;
    _writeLine('position fen $fen');

    EngineEvaluation? lastEval;
    final completer = Completer<void>();
    final sub = _stdoutLines.stream.listen((line) {
      if (line.startsWith('info ')) {
        final parsed = parseUciInfo(line);
        if (parsed != null && (parsed.centipawns != null || parsed.mate != null)) {
          lastEval = parsed;
        }
      } else if (line.startsWith('bestmove')) {
        if (!completer.isCompleted) completer.complete();
      }
    });

    _writeLine('go depth $depth');
    await completer.future;
    await sub.cancel();

    _writeLine('setoption name MultiPV value 5');
    return lastEval;
  }

  void _writeLine(String line) {
    if (_worker == null) return;
    _worker!.postMessage(line);
  }

  Future<void> _waitForLine(String expectedLine) async {
    await _stdoutLines.stream
        .firstWhere((line) => line.trim() == expectedLine)
        .timeout(commandTimeout);
  }

  @override
  Future<void> dispose() async {
    try {
      _writeLine('quit');
      _worker?.terminate();
    } catch (_) {}
    await _workerSubscription?.cancel();
    await _workerErrorSubscription?.cancel();
    await _evaluationController.close();
    _worker = null;
    _isStarted = false;
  }
}
