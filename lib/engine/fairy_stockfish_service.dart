// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

class FairyStockfishService {
  FairyStockfishService({
    this.binaryName = 'fairy-stockfish_x86-64-modern.exe',
    this.searchDepth = 12,
    this.commandTimeout = const Duration(seconds: 5),
    DatasetVariant initialVariant = DatasetVariant.koth,
  }) : _variant = initialVariant;

  DatasetVariant _variant;

  DatasetVariant get variant => _variant;

  bool get isNNUE {
    if (!_useNNUE) return false;
    if (_variant == DatasetVariant.standard) return true;
    return _resolveEvalFilePath() != null;
  }

  Future<void> setVariant(DatasetVariant variant) async {
    if (_variant == variant) return;
    _variant = variant;
    print('[engine] Configured variant: ${uciVariantForDataset(_variant)}');
    await _restart();
  }

  Future<void> newGame() async {
    if (!_isStarted || _process == null) return;
    _writeLine('stop');
    _writeLine('ucinewgame');
    await _sendAndWaitFor('isready', 'readyok');
  }

  final String binaryName;
  final int searchDepth;
  final Duration commandTimeout;

  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  final StreamController<String> _stdoutLines =
      StreamController<String>.broadcast();
  final StreamController<List<EngineEvaluation>> _evaluationController =
      StreamController<List<EngineEvaluation>>.broadcast();

  Stream<List<EngineEvaluation>> get evaluationStream =>
      _evaluationController.stream;

  final List<EngineEvaluation> _currentEvals = [];
  String _activeFen = "";

  Future<void> _evalQueue = Future<void>.value();
  bool _isStarted = false;
  bool _useNNUE = true;
  bool _isDisposed = false;

  /// True while we are waiting for readyok after a stop+isready sequence.
  /// Evaluations received during this window belong to the previous position
  /// and must be discarded.
  bool _waitingForReadyOk = false;

  Future<void> start() async {
    _isDisposed = false;
    if (_isStarted) return;
    if (!Platform.isWindows) return;

    final binaryPath = _resolveBinaryPath();
    if (binaryPath == null) {
      print('[engine] Binary not found: $binaryName');
      return;
    }

    try {
      _process = await Process.start(
        binaryPath,
        const [],
        workingDirectory: File(binaryPath).parent.path,
      );
    } catch (e) {
      print('[engine] Failed to start binary: $e');
      return;
    }

    _stdoutSubscription = _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (!line.startsWith('info ')) {
        print('[engine][out] $line');
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
        _currentEvals[idx - 1] = parsedInfo.copyWithFen(_activeFen);
        _evaluationController.add(List.from(_currentEvals));
      }
    });
    _stderrSubscription = _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => print('[engine][err] $line'));

    final currentProcess = _process!;
    currentProcess.exitCode.then((code) async {
      print('[engine] Process exited with code $code');
      if (_process != currentProcess) {
        return;
      }
      _isStarted = false;
      _process = null;

      if (!_isDisposed) {
        if (_useNNUE) {
          print('[engine] Engine exited unexpectedly. Retrying with NNUE disabled...');
          _useNNUE = false;
          await start();
        } else {
          print('[engine] Engine exited unexpectedly even without NNUE. Giving up.');
        }
      }
    });

    try {
      await _sendAndWaitFor('uci', 'uciok');

      if (!_useNNUE) {
        _writeLine('setoption name Use NNUE value false');
      }

      final evalFilePath = _useNNUE ? _resolveEvalFilePath() : null;
      if (evalFilePath != null) {
        _writeLine('setoption name EvalFile value $evalFilePath');
        print('[engine] Using EvalFile: $evalFilePath');
      } else {
        if (_variant == DatasetVariant.koth) {
          print('[engine] No kingofthehill*.nnue EvalFile found.');
        } else if (_variant == DatasetVariant.threeCheck) {
          print('[engine] No 3check*.nnue EvalFile found.');
        } else if (_variant == DatasetVariant.crazyhouse) {
          print('[engine] No crazyhouse*.nnue EvalFile found.');
        } else if (_variant == DatasetVariant.antichess) {
          print('[engine] No antichess*.nnue EvalFile found.');
        } else if (_variant == DatasetVariant.atomic) {
          print('[engine] No atomic*.nnue EvalFile found.');
        } else if (_variant == DatasetVariant.horde) {
          print('[engine] No horde*.nnue EvalFile found.');
        } else if (_variant == DatasetVariant.racingKings) {
          print('[engine] No racingkings*.nnue EvalFile found.');
        }
      }
      
      // Optimize search settings
      _writeLine('setoption name Threads value 8');
      _writeLine('setoption name Hash value 1024');
      
      _writeLine(
          'setoption name UCI_Variant value ${uciVariantForDataset(_variant)}');
      await _sendAndWaitFor('isready', 'readyok');
      _isStarted = true;
      print('[engine] Ready: $binaryPath');
      print('[engine] Using variant: ${uciVariantForDataset(_variant)}');

      // Automatically resume search if there is an active FEN
      if (_activeFen.isNotEmpty) {
        print('[engine] Resuming search for active FEN: $_activeFen');
        startSearch(_activeFen);
      }
    } catch (e) {
      print('[engine] Handshake failed: $e');
      await dispose();

      if (_useNNUE) {
        print('[engine] Retrying startup with NNUE disabled...');
        _useNNUE = false;
        await start();
      }
    }
  }

  Future<void> startSearch(String fen) async {
    _evalQueue = _evalQueue.then((_) => _startSearchImpl(fen));
  }

  Future<EngineEvaluation?> evaluatePositionSync(String fen, {int depth = 16}) async {
    if (!_isStarted || _process == null) await start();
    
    _waitingForReadyOk = true;
    _writeLine('stop');
    _writeLine('isready');
    await _waitForLine('readyok');
    // _waitingForReadyOk is cleared by the stdout listener on 'readyok'

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
    // Ensure we start the search for UI again if needed? 
    // Usually the caller will invoke startSearch after batch is done.
    return lastEval;
  }

  Future<void> dispose() async {
    _isDisposed = true;
    try {
      if (_process != null) {
        _writeLine('quit');
        _process!.kill();
      }
    } catch (_) {}

    await _stdoutSubscription?.cancel();
    await _stderrSubscription?.cancel();
    _stdoutSubscription = null;
    _stderrSubscription = null;
    _process = null;
    _isStarted = false;
    _useNNUE = true;
  }

  // The previous _runEvaluation was removed as we are streaming natively now.

  Future<void> _sendAndWaitFor(String command, String expectedLine) async {
    _writeLine(command);
    await _waitForLine(expectedLine);
  }

  Future<void> _waitForLine(String expectedLine) async {
    await _stdoutLines.stream
        .firstWhere((line) => line.trim() == expectedLine)
        .timeout(commandTimeout);
  }

  void _writeLine(String line) {
    final process = _process;
    if (process == null) throw StateError('Engine is not running.');
    print('[engine][in] $line');
    process.stdin.writeln(line);
  }

  String? _resolveBinaryPath() {
    final candidates = <String>[];
    final cwd = Directory.current.path;
    candidates.add('$cwd\\$binaryName');

    var probe = Directory(cwd);
    for (var i = 0; i < 6; i++) {
      candidates.add('${probe.path}\\$binaryName');
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir\\$binaryName');

    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }

  String? _resolveEvalFilePath() {
    final candidates = <Directory>[];
    final cwd = Directory.current.path;
    candidates.add(Directory(cwd));

    var probe = Directory(cwd);
    for (var i = 0; i < 6; i++) {
      candidates.add(probe);
      final parent = probe.parent;
      if (parent.path == probe.path) break;
      probe = parent;
    }

    final exeDir = Directory(File(Platform.resolvedExecutable).parent.path);
    candidates.add(exeDir);

    final seen = <String>{};
    
    RegExp regex;
    if (_variant == DatasetVariant.koth) {
      regex = RegExp(r'^kingofthehill.*\.nnue$', caseSensitive: false);
    } else if (_variant == DatasetVariant.threeCheck) {
      regex = RegExp(r'^3check.*\.nnue$', caseSensitive: false);
    } else if (_variant == DatasetVariant.crazyhouse) {
      regex = RegExp(r'^crazyhouse.*\.nnue$', caseSensitive: false);
    } else if (_variant == DatasetVariant.antichess) {
      regex = RegExp(r'^antichess.*\.nnue$', caseSensitive: false);
    } else if (_variant == DatasetVariant.atomic) {
      regex = RegExp(r'^atomic.*\.nnue$', caseSensitive: false);
    } else if (_variant == DatasetVariant.horde) {
      regex = RegExp(r'^horde.*\.nnue$', caseSensitive: false);
    } else if (_variant == DatasetVariant.racingKings) {
      regex = RegExp(r'^racingkings.*\.nnue$', caseSensitive: false);
    } else {
      return null;
    }

    for (final dir in candidates) {
      final dirPath = dir.path;
      if (!seen.add(dirPath)) continue;
      if (!dir.existsSync()) continue;
      final files = dir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => regex.hasMatch(_basename(f.path)))
          .toList();
      if (files.isNotEmpty) {
        return files.first.path;
      }
    }

    return null;
  }

  String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  Future<void> _restart() async {
    await dispose();
    await start();
  }

  Future<void> _startSearchImpl(String fen) async {
    if (!Platform.isWindows) return;
    if (!_isStarted || _process == null) {
      await start();
      if (!_isStarted || _process == null) return;
    }

    try {
      _currentEvals.clear();
      _waitingForReadyOk = true;
      _writeLine('stop');
      _writeLine('isready');
      await _waitForLine('readyok');
      // _waitingForReadyOk is cleared by the stdout listener on 'readyok'
      _writeLine('setoption name MultiPV value 5');
      _activeFen = fen;
      _writeLine('position fen $fen');
      _writeLine('go depth 16');
    } catch (e) {
      print('[engine] Search start failed: $e');
      await _restart();
    }
  }

  /// Whether the engine process is running and ready for commands.
  bool get isEngineAvailable => _isStarted && _process != null;
}
