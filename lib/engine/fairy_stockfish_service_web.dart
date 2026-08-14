// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:js_interop';
import 'package:web/web.dart' as web;
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
  bool _isNNUE = false;

  @override
  DatasetVariant get variant => _variant;

  @override
  bool get isNNUE => _isNNUE;

  web.Worker? _worker;
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

  String _nnueFilenameForVariant(DatasetVariant v) {
    switch (v) {
      case DatasetVariant.koth:
        return 'kingofthehill.nnue';
      case DatasetVariant.threeCheck:
        return '3check.nnue';
      case DatasetVariant.crazyhouse:
        return 'crazyhouse.nnue';
      case DatasetVariant.antichess:
        return 'antichess.nnue';
      case DatasetVariant.atomic:
        return 'atomic.nnue';
      case DatasetVariant.horde:
        return 'horde.nnue';
      case DatasetVariant.racingKings:
        return 'racingkings.nnue';
      case DatasetVariant.standard:
        return 'chess.nnue';
    }
  }

  @override
  Future<void> start() async {
    if (_isStarted && _worker != null) return;
    try {
      final base = web.window.document.baseURI;
      final workerUrl = web.URL(binaryName, base).href;
      print('[engine-web] Launching Web Worker $workerUrl for variant ${uciVariantForDataset(_variant)} (crossOriginIsolated: ${web.window.crossOriginIsolated})...');
      final worker = web.Worker(workerUrl.toJS);
      _worker = worker;
      _isNNUE = false;

      worker.onerror = ((web.ErrorEvent event) {
        print('[engine-web] Worker onerror: "${event.message}" at ${event.filename}:${event.lineno}:${event.colno}');
        _handleWorkerCrash();
      }).toJS;

      worker.onmessage = ((web.MessageEvent event) {
        final rawData = event.data;
        final line = rawData?.dartify()?.toString() ?? '';
        if (line.startsWith('WORKER_')) {
          print('[engine-web-worker-log] $line');
        }
        if (line.contains('NNUE evaluation') || line.contains('WORKER_NNUE_STATUS: enabled')) {
          _isNNUE = true;
        } else if (line.contains('classical evaluation') || line.contains('WORKER_NNUE_STATUS: classical')) {
          _isNNUE = false;
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
      }).toJS;

      _writeLine('uci');
      await _waitForLine('uciok', timeout: const Duration(seconds: 60));
      _writeLine('setoption name Threads value 1');
      _writeLine('setoption name Hash value 16');
      _writeLine('setoption name UCI_Variant value ${uciVariantForDataset(_variant)}');
      _writeLine('LOAD_NNUE ${_nnueFilenameForVariant(_variant)}');
      await _waitForLine('WORKER_NNUE_DONE', timeout: const Duration(seconds: 90));
      _writeLine('isready');
      await _waitForLine('readyok', timeout: const Duration(seconds: 60));
      _isStarted = true;
      print('[engine-web] Fairy-Stockfish WASM Worker ready for ${uciVariantForDataset(_variant)} (NNUE: $_isNNUE)');

      if (_activeFen.isNotEmpty) {
        startSearch(_activeFen);
      }
    } catch (e) {
      print('[engine-web] Failed to initialize Fairy-Stockfish WASM worker: $e');
      _handleWorkerCrash();
    }
  }

  void _handleWorkerCrash() {
    _isStarted = false;
    _isNNUE = false;
    try {
      _worker?.terminate();
    } catch (_) {}
    _worker = null;
  }

  @override
  Future<void> setVariant(DatasetVariant variant) async {
    if (_variant == variant && _isStarted) return;
    _variant = variant;
    await _restartWorker();
  }

  Future<void> _restartWorker() async {
    _isStarted = false;
    _isNNUE = false;
    try {
      _writeLine('quit');
      _worker?.terminate();
    } catch (_) {}
    _worker = null;
    _currentEvals.clear();
    _evaluationController.add([]);
    await start();
  }

  @override
  Future<void> newGame() async {
    if (!_isStarted || _worker == null) return;
    try {
      _writeLine('stop');
      _writeLine('ucinewgame');
      _writeLine('isready');
      await _waitForLine('readyok');
    } catch (e) {
      print('[engine-web] newGame error: $e');
    }
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
      _handleWorkerCrash();
    }
  }

  @override
  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16}) async {
    if (!_isStarted || _worker == null) await start();
    if (!_isStarted || _worker == null) return null;

    try {
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
      await completer.future.timeout(commandTimeout);
      await sub.cancel();

      _writeLine('setoption name MultiPV value 5');
      return lastEval;
    } catch (e) {
      print('[engine-web] evaluatePositionSync error: $e');
      return null;
    }
  }

  void _writeLine(String line) {
    if (_worker == null) return;
    _worker!.postMessage(line.toJS);
  }

  Future<void> _waitForLine(String expectedLine, {Duration? timeout}) async {
    await _stdoutLines.stream
        .firstWhere((line) => line.trim() == expectedLine)
        .timeout(timeout ?? commandTimeout);
  }

  @override
  Future<void> dispose() async {
    try {
      _writeLine('quit');
      _worker?.terminate();
    } catch (_) {}
    await _evaluationController.close();
    _worker = null;
    _isStarted = false;
    _isNNUE = false;
  }
}
