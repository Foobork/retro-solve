// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:file_selector/file_selector.dart';

import 'chess/chess.dart';
import 'dataset_variant.dart';
import 'config.dart';
import 'engine/fairy_stockfish_service.dart';
import 'graph/graph.dart';
import 'graph/graph_export.dart';
import 'graph/graph_import.dart';
import 'gui/chess_board.dart';
import 'gui/chess_board_controller.dart';
import 'persistence/database_service.dart';

class RetroSolve extends StatelessWidget {
  const RetroSolve({
    required this.initialVariant,
    required this.engineService,
    Key? key,
  }) : super(key: key);

  final DatasetVariant initialVariant;
  final FairyStockfishService engineService;

  @override
  Widget build(BuildContext context) {
    var theme = ThemeData(primarySwatch: Colors.deepPurple);
    return MaterialApp(
      title: 'Retro Solve',
      theme: theme,
      home: HomePage(
        initialVariant: initialVariant,
        engineService: engineService,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    required this.initialVariant,
    required this.engineService,
    Key? key,
  }) : super(key: key);

  final DatasetVariant initialVariant;
  final FairyStockfishService engineService;

  @override
  _HomePageState createState() => _HomePageState();
}

enum _MoreAction { solve, export_, analyzeGame }

class _HomePageState extends State<HomePage> {
  StreamSubscription<List<EngineEvaluation>>? _evalSub;
  Timer? _evalTimer;
  List<EngineEvaluation>? _pendingEvals;

  @override
  Widget build(BuildContext context) {
    var chessboard = ChessBoard(
      controller: _controller,
      boardColor: BoardColor.brown,
      boardOrientation: _orientation,
      enableUserMoves: !_isExploring,
    );
    var turn = Text(_turn, style: _textStyle);
    var appBar = AppBar(
      title: const Text('RetroSolve'),
      actions: [
        DropdownButtonHideUnderline(
          child: DropdownButton<DatasetVariant>(
            value: _variant,
            dropdownColor: Colors.deepPurple.shade50,
            onChanged: (_isLoadingVariant || _isExploring) ? null : (v) => _setVariant(v),
            items: DatasetVariant.values
                .map(
                  (v) => DropdownMenuItem(
                    value: v,
                    child: Text(v.label),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(width: 12),
      ],
    );

    var body = Center(
      child: _padded(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Column(
              children: <Widget>[
                Expanded(child: chessboard),
                turn,
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _button("reset", _reset),
                    _button("back", _back),
                    _button("flip", _flip),
                    _button(_isExploring ? "stop exploring" : "explore",
                        _exploreToggle),
                    PopupMenuButton<_MoreAction>(
                      tooltip: 'More actions',
                      onSelected: _onMoreAction,
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: _MoreAction.solve,
                          child: Text('Solve'),
                        ),
                        PopupMenuItem(
                          value: _MoreAction.export_,
                          child: Text('Export'),
                        ),
                        PopupMenuItem(
                          value: _MoreAction.analyzeGame,
                          child: Text('Analyze Game'),
                        ),
                      ],
                    ),
                    if (Config.showBatchEval)
                      _button(
                          "batch eval", _isBatchEvaluating ? null : _batchEval),
                  ],
                ),
              ],
            ),
            Expanded(
              child: _movesColumn(),
            ),
            Expanded(
              child: _engineColumn(),
            )
          ],
        ),
      ),
    );

    return Scaffold(
      appBar: appBar,
      body: Stack(
        children: [
          body,
          if (_isLoadingVariant)
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
    );
  }

  final _controller = ChessBoardController();
  final _textStyle = const TextStyle(fontSize: 20);

  late DatasetVariant _variant;
  bool _isLoadingVariant = false;
  List<MoveInfo> _knownMoves = [];
  String _bfen = "";
  String _eval = "";
  List<EngineEvaluation> _engineEvals = [];
  bool _engineAvailable = false;
  bool _engineEvalPending = false;
  String _turn = "";
  PlayerColor _orientation = white;
  final TextEditingController _evalController = TextEditingController();

  bool _isBatchEvaluating = false;
  bool _isExploring = false;
  int _evalProgress = 0;
  int _evalTotal = 0;
  String _batchTimeText = "";

  TableRow _buildMoveRow(String move, String evalStr, {Color? color}) {
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, right: 28.0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                alignment: Alignment.centerLeft,
              ),
              onPressed: _isExploring
                  ? null
                  : () => _controller.makeMoveWithNormalNotation(move),
              child: Text(move,
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, right: 16.0),
          child: Text(
            evalStr,
            style: TextStyle(
                fontSize: 20,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()]),
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }

  _movesTable() {
    var rows = _knownMoves.map((MoveInfo info) {
      String evalStr = "";
      if (info.eval != null) {
        evalStr = _formatScore(info.eval!, isMoveScore: true);
      }
      return _buildMoveRow(info.move, evalStr);
    }).toList();

    return _padded(
      Table(
        columnWidths: const <int, TableColumnWidth>{
          0: IntrinsicColumnWidth(),
          1: IntrinsicColumnWidth(),
        },
        children: rows,
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      ),
    );
  }

  _movesColumn() {
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _evaluationWidget(),
          Expanded(
            child: SingleChildScrollView(
              child: _movesTable(),
            ),
          ),
        ],
      ),
    );
  }

  _engineColumn() {
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _engineWidget(),
          if (Config.showBatchEval && _isBatchEvaluating)
            Padding(
              padding: const EdgeInsets.only(top: 16.0, bottom: 8.0),
              child: Text(
                "Evaluating $_evalProgress / $_evalTotal",
                style: const TextStyle(
                    fontSize: 14,
                    color: Colors.blue,
                    fontWeight: FontWeight.bold),
              ),
            ),
          if (Config.showBatchEval && _isBatchEvaluating)
            LinearProgressIndicator(
              value: _evalTotal > 0 ? _evalProgress / _evalTotal : 0,
              backgroundColor: Colors.grey[300],
            ),
          if (Config.showBatchEval &&
              _isBatchEvaluating &&
              _batchTimeText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8.0),
              child: Text(
                _batchTimeText,
                style: const TextStyle(fontSize: 12, color: Colors.blueGrey),
              ),
            ),
        ],
      ),
    );
  }

  _HomePageState() {
    _update();
    _controller.addListener(_chessBoardListener);
    graph.onNodeUpdated = (bfen, assigned, computed) {
      DatabaseService.instance.upsertNode(bfen, assigned, computed);
    };
    graph.onEdgeAdded = (source, target) {
      DatabaseService.instance.upsertEdge(source, target);
    };
  }

  @override
  void initState() {
    super.initState();
    _variant = widget.initialVariant;
    _controller.setGame(_createGameForVariant(_variant));
    _controller.game.reset();
    _engineAvailable = widget.engineService.isEngineAvailable;
    _evalSub = widget.engineService.evaluationStream.listen((evals) {
      if (!mounted || _isBatchEvaluating) return;
      _pendingEvals = evals;
      if (_evalTimer == null || !_evalTimer!.isActive) {
        _evalTimer = Timer(const Duration(milliseconds: 150), () {
          if (!mounted || _pendingEvals == null) return;
          final currentFen = _controller.game.fen;
          final whiteToMove = _controller.game.turn == white;
          final validEvals = _pendingEvals!
              .where((e) =>
                  (e.centipawns != null || e.mate != null) &&
                  e.fen != null &&
                  Chess.normalizeFen(e.fen!) == Chess.normalizeFen(currentFen))
              .map((e) => e.asWhitePerspective(whiteToMove: whiteToMove))
              .toList();

          setState(() {
            _engineEvalPending = false;
            _engineEvals = validEvals;

            // Auto-populate node directly if not in database and depth is sufficient
            final bfen = _controller.game.bfen;
            final fen = _controller.game.fen;
            if (graph.v[bfen]?.assigned == null && _engineEvals.isNotEmpty) {
              final bestEval = _engineEvals.first;
              if (bestEval.fen == fen &&
                  (bestEval.mate != null ||
                      (bestEval.depth != null && bestEval.depth! >= 16))) {
                final score = _engineEvalToGraphScore(bestEval, whiteToMove);
                if (score != null) {
                  graph.assign(bfen, score);
                  graph.v[bfen]?.inDatabase = true;
                  graph.solveBfen(bfen);
                  // _export(); // Incremental via onNodeUpdated

                  // Dynamically update the UI eval box
                  _eval = score.toString();
                  if (_evalController.text != _eval) {
                    _evalController.text = _eval;
                  }
                }
              }
            }
          });
        });
      }
    });
    _update();
  }

  @override
  void dispose() {
    _evalController.dispose();
    _evalTimer?.cancel();
    _evalSub?.cancel();
    widget.engineService.dispose();
    super.dispose();
  }

  Future<void> _setVariant(DatasetVariant? v) async {
    if (v == null) return;
    if (v == _variant) return;

    setState(() {
      _variant = v;
      _isLoadingVariant = true;
    });
    await widget.engineService.setVariant(_variant);
    await widget.engineService.newGame();
    _controller.setGame(_createGameForVariant(_variant));
    _controller.resetBoard();

    // Let the loading overlay paint before we block.
    await Future<void>.delayed(const Duration(milliseconds: 16));

    final file = File(_variant.dataPath);
    final dbPath = _variant.dataPath.replaceAll('.txt', '.db');
    final dbFile = File(dbPath);
    if (!file.existsSync() && !dbFile.existsSync()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Dataset file not found; initializing empty database for ${_variant.label}.',
            ),
          ),
        );
      }
    }

    resetGraph();
    // Re-hook the callback after reset
    graph.onNodeUpdated = (bfen, assigned, computed) {
      DatabaseService.instance.upsertNode(bfen, assigned, computed);
    };
    graph.onEdgeAdded = (source, target) {
      DatabaseService.instance.upsertEdge(source, target);
    };

    await importGraph(_variant.dataPath);
    await DatasetVariantStore.save(_variant);

    if (!mounted) return;
    setState(() {
      _isLoadingVariant = false;
      _update();
    });
  }

  void _chessBoardListener() {
    var game = _controller.game.copy();
    String a = game.bfen;
    bool assignedAny = false;
    if (game.gameOver) {
      final score = game.terminalEvaluation;
      if (score != null && graph.v[a]?.assigned == null) {
        graph.assign(a, score);
        assignedAny = true;
      }
      if (assignedAny) {
        graph.solveBfen(a);
      }
      setState(_update);
      return;
    }

    List<Move> moves = game.generateMoves();
    for (var move in moves) {
      game.makeMove(move);
      String b = game.bfen;
      if (game.gameOver) {
        final score = game.terminalEvaluation;
        if (score != null && graph.v[b]?.assigned == null) {
          graph.assign(b, score);
          assignedAny = true;
        }
      }
      game.undo();
      graph.addLink(a, b);
    }
    if (assignedAny) {
      graph.solveBfen(a);
    }
    setState(_update);
  }

  void _update() {
    _knownMovesToSan();
    _bfen = _controller.game.bfen;
    if (_controller.game.isThreeCheck) {
      final wChecks = _controller.game.checksCount[white];
      final bChecks = _controller.game.checksCount[black];
      _turn = _controller.game.turn == white
          ? "White to move ($wChecks+$bChecks)"
          : "Black to move ($wChecks+$bChecks)";
    } else {
      _turn = _controller.game.turn == white ? "White to move" : "Black to move";
    }
    Clipboard.setData(ClipboardData(text: _bfen));
    final vertex = graph.v[_bfen];
    if (vertex != null) {
      final assigned = vertex.assigned;
      final computed = vertex.computed;
      _eval = assigned != null
          ? _formatScore(assigned)
          : (computed != null ? _formatScore(computed, wrapInParentheses: true) : "");
    } else {
      _eval = "";
    }
    if (_evalController.text != _eval) {
      _evalController.text = _eval;
    }
    if (_engineAvailable) {
      _engineEvalPending = true;
      _requestEngineEval();
    } else {
      _engineEvalPending = false;
      _engineEvals = [];
    }
  }

  void _requestEngineEval() {
    if (!_engineAvailable) return;
    final fen = _controller.game.fen;
    setState(() {
      _engineEvalPending = true;
      _engineEvals = [];
    });
    widget.engineService.startSearch(fen);
  }

  _compare(PlayerColor turn) => (MoveInfo i, MoveInfo j) {
        var a = i.eval;
        var b = j.eval;

        return a == null
            ? b == null
                ? 0
                : 1
            : b == null
                ? 0
                : turn == white
                    ? b.compareTo(a)
                    : a.compareTo(b);
      };

  void _knownMovesToSan() {
    _knownMoves = [];
    _controller.getPossibleMoves().forEach(_addMoveIfKnown);
    _knownMoves.sort(_compare(_controller.game.turn));
    print('[KNOWN-MOVES] bfen="${_controller.game.bfen}" count=${_knownMoves.length} moves=${_knownMoves.map((m) => "${m.move} (${m.eval})").toList()}');
  }

  void _addMoveIfKnown(Move move) {
    var game = _controller.game.copy();
    var scratch = game.copy();
    scratch.makeMove(move);
    var vertex = graph.v[scratch.bfen];
    if (vertex == null) return;
    if (!vertex.inDatabase && vertex.assigned == null && vertex.computed == null && vertex.links.isEmpty) return;
    _knownMoves.add(MoveInfo(game.moveToSan(move), vertex.computed ?? vertex.assigned));
  }

  void _back() {
    _controller.undoMove();
  }

  void _reset() {
    _controller.resetBoard();
  }

  void _doFlip() {
    _orientation = _orientation == white ? black : white;
  }

  void _flip() {
    setState(_doFlip);
  }

  void _export() {
    exportGraph(_variant.dataPath);
  }

  void _solve() {
    graph.solve();
    // _export(); // Incremental via onNodeUpdated
  }

  void _onMoreAction(_MoreAction action) {
    switch (action) {
      case _MoreAction.solve:
        _solve();
        break;
      case _MoreAction.export_:
        _export();
        break;
      case _MoreAction.analyzeGame:
        _pickAndAnalyzeGame();
        break;
    }
  }

  void _exploreToggle() {
    if (_isExploring) {
      setState(() => _isExploring = false);
    } else {
      _startExploring();
    }
  }

  Future<void> _startExploring() async {
    if (!_engineAvailable) return;
    setState(() => _isExploring = true);
    WakelockPlus.enable();
    print('[explore] Started exploring');

    try {
      await _exploreRecursive(isRoot: true);
    } finally {
      if (mounted) setState(() => _isExploring = false);
      WakelockPlus.disable();
      print('[explore] Exploration ended/stopped.');
    }
  }

  Future<void> _exploreRecursive({required bool isRoot}) async {
    if (!_isExploring || !mounted) return;

    // Wait for the evaluation of the current position to stabilize at depth 16
    while (_isExploring &&
        mounted &&
        (_engineEvalPending || _engineEvals.isEmpty)) {
      await Future.delayed(const Duration(milliseconds: 100));
    }
    while (_isExploring && mounted) {
      if (_engineEvals.isNotEmpty) {
        final bestEval = _engineEvals.first;
        if (bestEval.mate != null ||
            (bestEval.depth != null && bestEval.depth! >= 16)) {
          break;
        }
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (!_isExploring || !mounted) return;

    final knownMoveSans = _getKnownMoveSans();

    if (!isRoot) {
      if (knownMoveSans.isEmpty) {
        print(
            '[explore] No branches have been explored from this position. Backing up.');
        return;
      }

      bool hasUnexplored = false;
      for (final e in _engineEvals) {
        String san = _uciToSan(e.candidateMove);
        if (san != '—' && !knownMoveSans.contains(san)) {
          hasUnexplored = true;
          break;
        }
      }

      if (!hasUnexplored) {
        print(
            '[explore] All engine moves have been explored from this position. Backing up.');
        return;
      }
    }

    while (_isExploring && mounted) {
      final currentKnownSans = _getKnownMoveSans();
      String? nextMoveToExplore;

      for (final e in _engineEvals) {
        String san = _uciToSan(e.candidateMove);
        if (san != '—' && !currentKnownSans.contains(san)) {
          nextMoveToExplore = san;
          break;
        }
      }

      if (nextMoveToExplore == null) {
        if (isRoot) {
          print('[explore] No more unexplored moves found at root. Stopping.');
        }
        break;
      }

      print(
          '[explore] Choosing to explore unexplored move: $nextMoveToExplore');
      _controller.makeMoveWithNormalNotation(nextMoveToExplore);

      await Future.delayed(const Duration(milliseconds: 200));

      while (_isExploring && mounted) {
        final bfen = _controller.game.bfen;
        if (graph.v[bfen]?.assigned != null) break;
        await Future.delayed(const Duration(milliseconds: 100));
      }

      if (!_isExploring || !mounted) break;
      print(
          '[explore] Back-solved evaluation for $nextMoveToExplore completed.');

      // Recursively explore the resulting position
      await _exploreRecursive(isRoot: false);

      if (!_isExploring || !mounted) break;

      print('[explore] Returning to parent position.');
      _controller.undoMove();

      await Future.delayed(const Duration(milliseconds: 200));

      // Wait for stabilization after undoing the move
      while (_isExploring &&
          mounted &&
          (_engineEvalPending || _engineEvals.isEmpty)) {
        await Future.delayed(const Duration(milliseconds: 100));
      }
      while (_isExploring && mounted) {
        if (_engineEvals.isNotEmpty) {
          final bestEval = _engineEvals.first;
          if (bestEval.mate != null ||
              (bestEval.depth != null && bestEval.depth! >= 16)) {
            break;
          }
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  Future<void> _pickAndAnalyzeGame() async {
    const XTypeGroup typeGroup = XTypeGroup(
      label: 'PGN files',
      extensions: <String>['pgn', 'txt'],
    );
    final XFile? file =
        await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);
    if (file == null) return;

    final String pgnText = await file.readAsString();
    if (pgnText.isNotEmpty) {
      _analyzeGame(pgnText);
    }
  }

  Future<void> _analyzeGame(String pgnText) async {
    final tempGame = Chess();
    if (!tempGame.loadPgn(pgnText)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to parse PGN')),
        );
      }
      return;
    }

    final rawMoves = tempGame.sanMoves();
    final List<String> moves = [];
    for (final raw in rawMoves) {
      if (raw == null) continue;
      final parts = raw.split(' ');
      for (final p in parts) {
        if (!p.contains('.') &&
            p.isNotEmpty &&
            !['1/2-1/2', '1-0', '0-1', '*'].contains(p)) {
          moves.add(p);
        }
      }
    }

    _reset();
    if (!_engineAvailable) return;
    setState(() => _isExploring = true);
    WakelockPlus.enable();
    print('[analyze] Started analyzing game');

    try {
      // Analyze starting position
      await _exploreRecursive(isRoot: true);

      // Play through moves
      for (final san in moves) {
        if (!_isExploring || !mounted) break;

        print('[analyze] Playing move: $san');
        _controller.makeMoveWithNormalNotation(san);

        // Wait for board to update and engine to start
        await Future.delayed(const Duration(milliseconds: 200));

        // Analyze new position
        await _exploreRecursive(isRoot: true);
      }
    } finally {
      if (mounted) setState(() => _isExploring = false);
      WakelockPlus.disable();
      print('[analyze] Game analysis ended/stopped.');
    }
  }

  void _batchEval() async {
    if (_isBatchEvaluating || !_engineAvailable) return;
    setState(() {
      _isBatchEvaluating = true;
      _evalTotal = graph.v.length;
      _evalProgress = 0;
      _batchTimeText = "";
    });
    WakelockPlus.enable();

    final stopwatch = Stopwatch()..start();
    int lastElapsed = 0;
    final List<int> recentTimes = [];

    final keys = graph.v.keys.where((k) => graph.v[k]!.inDatabase).toList();
    setState(() {
      _evalTotal = keys.length;
    });

    for (String bfen in keys) {
      if (!mounted) break;
      final fen = '$bfen 0 1';
      final evalRaw =
          await widget.engineService.evaluatePositionSync(fen, depth: 16);
      if (evalRaw != null) {
        final isWhiteToMove = graph.v[bfen]!.whiteToMove;
        final eval = evalRaw.asWhitePerspective(whiteToMove: isWhiteToMove);
        final score = _engineEvalToGraphScore(eval, isWhiteToMove);
        if (score != null) {
          graph.assign(bfen, score);
        }
      }
      final currentElapsed = stopwatch.elapsedMilliseconds;
      recentTimes.add(currentElapsed - lastElapsed);
      if (recentTimes.length > 25) {
        recentTimes.removeAt(0);
      }
      lastElapsed = currentElapsed;

      setState(() {
        _evalProgress++;
        if (recentTimes.isNotEmpty) {
          final sum = recentTimes.reduce((a, b) => a + b);
          final msPerEval = sum / recentTimes.length;
          final remainingMs = msPerEval * (_evalTotal - _evalProgress);
          final remaining = Duration(milliseconds: remainingMs.toInt());

          String formatDur(Duration d) =>
              '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

          _batchTimeText =
              "Elapsed: ${formatDur(stopwatch.elapsed)} | ETA: ${formatDur(remaining)}";
        }
      });
    }

    stopwatch.stop();
    final totalElapsed = stopwatch.elapsed;
    print(
        "Batch Evaluation Completed in ${totalElapsed.inMinutes}m ${(totalElapsed.inSeconds % 60)}s");

    WakelockPlus.disable();

    if (mounted) {
      setState(() {
        _isBatchEvaluating = false;
      });
      _solve();
      _requestEngineEval();
    }
  }

  _button(text, action) {
    var child = Text(text, style: _textStyle);
    return TextButton(child: child, onPressed: action);
  }

  _padded(child) {
    var padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 8);
    return Container(padding: padding, child: child);
  }

  _evaluationWidget() {
    return _textField("Evaluation", _evalController, _updateEval);
  }

  Set<String> _getKnownMoveSans() {
    final set = <String>{};
    for (final m in _knownMoves) {
      set.add(m.move);
      set.add(_controller.game.normalizeMoveString(m.move));
    }
    return set;
  }

  String _uciToSan(String? uci) {
    if (uci == null || uci.isEmpty) {
      print('[UCI-TO-SAN] uci is null or empty');
      return '—';
    }
    final cleanUci = uci.trim().replaceAll('-', '').toLowerCase();
    final game = _controller.game.copy();
    final moves = game.generateMoves();
    for (final m in moves) {
      final mUci =
          '${m.fromAlgebraic}${m.toAlgebraic}${m.promotion?.name ?? ''}'.toLowerCase();
      final san = game.moveToSan(m);
      if (mUci == cleanUci || san.toLowerCase() == cleanUci) {
        print('[UCI-TO-SAN-MATCH] uci="$uci" -> SAN="$san" (mUci="$mUci")');
        return san;
      }
    }
    print('[UCI-TO-SAN-NO-MATCH] uci="$uci" cleanUci="$cleanUci" fen="${game.fen}" turn="${game.turn}" halfMoves=${game.halfMoves} historyLen=${game.history.length} availableMoves=${moves.map((m) => '${m.fromAlgebraic}${m.toAlgebraic}').toList()}');
    return uci;
  }

  Widget _engineWidget() {
    Widget content;
    final currentFen = _controller.game.fen;
    final validEngineEvals = _engineEvals
        .where((e) => e.fen != null && Chess.normalizeFen(e.fen!) == Chess.normalizeFen(currentFen))
        .toList();

    print('[ENGINE-WIDGET] currentFen="$currentFen" totalEvals=${_engineEvals.length} validEvals=${validEngineEvals.length} candidates=${validEngineEvals.map((e) => "${e.candidateMove} (fen=${e.fen})").toList()}');

    if (_engineEvalPending || validEngineEvals.isEmpty) {
      content = Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_engineEvalPending)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (_engineEvalPending) const SizedBox(width: 8),
          const Expanded(
            child: Text('—', style: TextStyle(fontSize: 20)),
          ),
        ],
      );
    } else {
      final depth = validEngineEvals.first.depth;
      final knownMoveSans = _getKnownMoveSans();
      final rows = validEngineEvals.map((e) {
        String san = _uciToSan(e.candidateMove);
        String evalStr = 'unknown';
        if (e.mate != null) {
          if (e.mate == 0) {
            final score =
                _engineEvalToGraphScore(e, _controller.game.turn == white);
            evalStr = score! > 0 ? '+M0' : '-M0';
          } else {
            evalStr = e.mate! > 0 ? '+M${e.mate!}' : '-M${e.mate!.abs()}';
          }
        } else if (e.centipawns != null) {
          final pawns = e.centipawns! / 100.0;
          evalStr = pawns > 0
              ? '+${pawns.toStringAsFixed(2)}'
              : pawns.toStringAsFixed(2);
        }

        final isKnown = knownMoveSans.contains(san) ||
            knownMoveSans.contains(_controller.game.normalizeMoveString(san));
        final bool shouldHighlight = !isKnown && san != '—';
        return _buildMoveRow(san, evalStr,
            color: shouldHighlight ? Colors.blue : null);
      }).toList();

      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (depth != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12.0),
              child: Text('Depth $depth',
                  style: const TextStyle(fontSize: 16, color: Colors.black54)),
            ),
          Table(
            columnWidths: const <int, TableColumnWidth>{
              0: IntrinsicColumnWidth(),
              1: IntrinsicColumnWidth(),
            },
            children: rows,
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 200,
          child: InputDecorator(
            decoration: InputDecoration(
              labelText: widget.engineService.isNNUE ? 'Engine (NNUE)' : 'Engine (Classical)',
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(12),
            ),
            child: content,
          ),
        ),
      ],
    );
  }

  _updateEval(String newEval) {
    String bfen = _controller.game.bfen;
    graph.assign(bfen, _parseScore(newEval));
    graph.v[bfen]?.inDatabase = true;
    graph.solveBfen(bfen);
    // _export(); // Incremental via onNodeUpdated
  }

  _textField(label, TextEditingController controller, onSubmitted) {
    return SizedBox(
      width: 200,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          label: Text(label),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: onSubmitted,
      ),
    );
  }

  double? _engineEvalToGraphScore(EngineEvaluation eval, bool isWhiteToMove) {
    if (eval.mate != null) {
      final m = eval.mate!;
      if (m == 0) {
        return isWhiteToMove ? -1000.0 : 1000.0;
      } else {
        int pliesToMate;
        if (m > 0) {
          pliesToMate = isWhiteToMove ? (2 * m - 1) : (2 * m);
          return 1000.0 - pliesToMate;
        } else {
          int mAbs = m.abs();
          pliesToMate = isWhiteToMove ? (2 * mAbs) : (2 * mAbs - 1);
          return -1000.0 + pliesToMate;
        }
      }
    } else if (eval.centipawns != null) {
      return eval.centipawns! / 100.0;
    }
    return null;
  }

  String _formatScore(double score, {bool wrapInParentheses = false, bool isMoveScore = false}) {
    const double mateThreshold = 900.0;
    String formatted;
    if (score.abs() >= mateThreshold) {
      double adjustedScore = score;
      if (isMoveScore) {
        if (score > 0) {
          adjustedScore = score - 1.0;
        } else {
          adjustedScore = score + 1.0;
        }
      }
      if (adjustedScore > 0) {
        final plies = (1000.0 - adjustedScore).round();
        final moves = (plies + 1) ~/ 2;
        formatted = '+M$moves';
      } else {
        final plies = (adjustedScore + 1000.0).round();
        final moves = (plies + 1) ~/ 2;
        formatted = '-M$moves';
      }
    } else {
      formatted = score > 0 ? '+${score.toStringAsFixed(2)}' : score.toStringAsFixed(2);
    }
    return wrapInParentheses ? '($formatted)' : formatted;
  }

  double? _parseScore(String text) {
    text = text.trim();
    if (text.isEmpty) return null;
    
    if (text.startsWith('(') && text.endsWith(')')) {
      text = text.substring(1, text.length - 1).trim();
    }
    
    final mateRegex = RegExp(r'^([+-]?)M(\d+)$', caseSensitive: false);
    final match = mateRegex.firstMatch(text);
    if (match != null) {
      final sign = match.group(1) == '-' ? -1 : 1;
      final moves = int.parse(match.group(2)!);
      final plies = moves * 2;
      return sign > 0 ? 1000.0 - plies : -1000.0 + plies;
    }
    
    return double.tryParse(text);
  }

  Chess _createGameForVariant(DatasetVariant variant) {
    switch (variant) {
      case DatasetVariant.threeCheck:
        return ThreeCheckChess();
      case DatasetVariant.koth:
        return KothChess();
      case DatasetVariant.crazyhouse:
        return CrazyhouseChess();
      case DatasetVariant.antichess:
        return AntichessChess();
      case DatasetVariant.atomic:
        return AtomicChess();
      case DatasetVariant.horde:
        return HordeChess();
      case DatasetVariant.racingKings:
        return RacingKingsChess();
      case DatasetVariant.standard:
      default:
        return Chess();
    }
  }
}

class MoveInfo {
  String move;
  double? eval;

  MoveInfo(this.move, this.eval);
}
