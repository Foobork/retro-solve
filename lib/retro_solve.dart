// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:file_selector/file_selector.dart';

import 'chess/chess.dart';
import 'chess/pgn_parser.dart';
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
  final EngineService engineService;

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
  final EngineService engineService;

  @override
  HomePageState createState() => HomePageState();
}

enum _MoreAction { solve, export_, analyzeGame }

class HomePageState extends State<HomePage> {
  StreamSubscription<List<EngineEvaluation>>? _evalSub;
  Timer? _evalTimer;
  List<EngineEvaluation>? _pendingEvals;

  @override
  Widget build(BuildContext context) {
    final bool isBoardDisabled =
        _isExploring || _isAnalyzingGame || _isBatchEvaluating || _isLoadingVariant || _isPickingFile;

    var chessboard = IgnorePointer(
      ignoring: isBoardDisabled,
      child: ChessBoard(
        controller: _controller,
        boardColor: BoardColor.brown,
        boardOrientation: _orientation,
        enableUserMoves: !isBoardDisabled,
      ),
    );
    var turn = Text(_turn, style: _textStyle);
    var appBar = AppBar(
      title: const Text('RetroSolve'),
      actions: [
        DropdownButtonHideUnderline(
          child: DropdownButton<DatasetVariant>(
            value: _variant,
            dropdownColor: Colors.deepPurple.shade50,
            onChanged: isBoardDisabled ? null : (v) => _setVariant(v),
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

    final moreMenu = PopupMenuButton<_MoreAction>(
      tooltip: 'More actions',
      enabled: !isBoardDisabled,
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
    );

    final actionButtons = Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 2,
      children: [
        _button("reset", isBoardDisabled ? null : _reset),
        _button("back", isBoardDisabled ? null : _back),
        _button("flip", _flip),
        _button(_isExploring ? "stop exploring" : "explore",
            (_isPickingFile || _isAnalyzingGame) ? null : _exploreToggle),
        moreMenu,
        if (Config.showBatchEval)
          _button("batch eval", isBoardDisabled ? null : _batchEval),
      ],
    );

    var body = LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 800;

        if (isNarrow) {
          final boardSize = (constraints.maxWidth - 24).clamp(100.0, 440.0);
          return SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: boardSize,
                  child: chessboard,
                ),
                const SizedBox(height: 8),
                turn,
                const SizedBox(height: 4),
                actionButtons,
                const Divider(height: 20),
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.start,
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    _evaluationWidget(),
                    _engineWidget(),
                  ],
                ),
                if (_isAnalyzingGame) ...[
                  const SizedBox(height: 12),
                  _analyzeGameProgress(),
                ],
                if (Config.showBatchEval && _isBatchEvaluating) ...[
                  const SizedBox(height: 12),
                  _batchEvalProgress(),
                ],
                const SizedBox(height: 16),
                const Text('Known Moves',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 8),
                _movesTable(),
                const SizedBox(height: 32),
              ],
            ),
          );
        }

        return Center(
          child: _padded(
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: <Widget>[
                      Expanded(
                        child: Center(
                          child: chessboard,
                        ),
                      ),
                      const SizedBox(height: 6),
                      turn,
                      const SizedBox(height: 4),
                      actionButtons,
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 250,
                  child: _movesColumn(),
                ),
                const SizedBox(width: 16),
                SizedBox(
                  width: 250,
                  child: _engineColumn(),
                ),
              ],
            ),
          ),
        );
      },
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
  @visibleForTesting
  ChessBoardController get controller => _controller;
  @visibleForTesting
  void setEngineEvalsForTesting(List<EngineEvaluation> evals) {
    setState(() {
      _engineEvals = evals;
    });
  }
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

  bool _isAnalyzingGame = false;
  bool _isPickingFile = false;
  int _analyzeProgress = 0;
  int _analyzeTotal = 0;
  String _analyzeTimeText = "";
  String _analyzeChapterText = "";
  final Stopwatch _analyzeStopwatch = Stopwatch();

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

  Widget _batchEvalProgress() {
    final percent = _evalTotal > 0 ? (_evalProgress / _evalTotal).clamp(0.0, 1.0) : 0.0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            "Evaluating $_evalProgress / $_evalTotal (${(percent * 100).toStringAsFixed(1)}%)",
            style: const TextStyle(
              fontSize: 13,
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 6,
              backgroundColor: Colors.blue.shade100,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 16,
            child: Text(
              _batchTimeText.isNotEmpty ? _batchTimeText : "Calculating ETA...",
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  Widget _analyzeGameProgress() {
    final percent = _analyzeTotal > 0
        ? (_analyzeProgress / _analyzeTotal).clamp(0.0, 1.0)
        : 0.0;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.blue.shade200),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_analyzeChapterText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2.0),
              child: Text(
                _analyzeChapterText,
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.blue.shade900,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          Text(
            "Position $_analyzeProgress / $_analyzeTotal (${(percent * 100).toStringAsFixed(1)}%)",
            style: const TextStyle(
              fontSize: 13,
              color: Colors.blue,
              fontWeight: FontWeight.bold,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent,
              minHeight: 6,
              backgroundColor: Colors.blue.shade100,
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.blue),
            ),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 16,
            child: Text(
              _analyzeTimeText.isNotEmpty ? _analyzeTimeText : "Calculating ETA...",
              style: TextStyle(fontSize: 11, color: Colors.blueGrey.shade700),
              textAlign: TextAlign.center,
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
          if (_isAnalyzingGame)
            _analyzeGameProgress(),
          if (Config.showBatchEval && _isBatchEvaluating)
            _batchEvalProgress(),
          Expanded(
            child: SingleChildScrollView(
              child: _engineWidget(),
            ),
          ),
        ],
      ),
    );
  }

  HomePageState() {
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
          final currentKey = EngineCache.canonicalKey(_variant, currentFen);
          final whiteToMove = _controller.game.turn == white;
          final validEvals = _pendingEvals!
              .where((e) =>
                  (e.centipawns != null || e.mate != null) &&
                  e.fen != null &&
                  EngineCache.canonicalKey(_variant, e.fen!) == currentKey &&
                  (e.candidateMove == null ||
                      EngineCache.isMoveColorConsistentWithFen(currentFen, e.candidateMove!)))
              .map((e) => e.asWhitePerspective(whiteToMove: whiteToMove))
              .toList();

          setState(() {
            _engineEvalPending = widget.engineService.isSearching;
            if (validEvals.isNotEmpty) {
              _engineEvals = validEvals;
            }

            // Auto-populate node directly if not in database and depth is sufficient
            final bfen = _controller.game.bfen;
            if (graph.v[bfen]?.assigned == null && _engineEvals.isNotEmpty) {
              final bestEval = _engineEvals.first;
              final bool isSufficient = bestEval.mate != null ||
                  (bestEval.depth != null && bestEval.depth! >= 16) ||
                  (!widget.engineService.isSearching && bestEval.depth != null);
              if (bestEval.fen != null &&
                  EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey &&
                  isSufficient) {
                final score = _engineEvalToGraphScore(bestEval, _controller.game.turn == white);
                if (score != null) {
                  graph.assign(bfen, score);
                  graph.v[bfen]?.inDatabase = true;
                  graph.solveBfen(bfen);
                  _knownMovesToSan();
                  final assigned = graph.v[bfen]?.assigned;
                  final computed = graph.v[bfen]?.computed;
                  if (computed != null) {
                    final bool isSameAsAssigned =
                        assigned != null && (computed - assigned).abs() < 1e-6;
                    _eval = isSameAsAssigned
                        ? _formatScore(assigned)
                        : _formatScore(computed, wrapInParentheses: true);
                  } else if (assigned != null) {
                    _eval = _formatScore(assigned);
                  }
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
    if (game.gameOver) {
      final score = game.terminalEvaluation;
      if (score != null && graph.v[a]?.assigned == null) {
        graph.assign(a, score);
      }
      graph.solveBfen(a);
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
        }
      }
      game.undo();
      graph.addLink(a, b);
    }
    graph.solveBfen(a);
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
      if (computed != null) {
        final bool isSameAsAssigned =
            assigned != null && (computed - assigned).abs() < 1e-6;
        _eval = isSameAsAssigned
            ? _formatScore(assigned)
            : _formatScore(computed, wrapInParentheses: true);
      } else if (assigned != null) {
        _eval = _formatScore(assigned);
      } else {
        _eval = "";
      }
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
    final whiteToMove = _controller.game.turn == white;
    final cached = widget.engineService.getCachedEvaluation(fen, minDepth: 16);
    if (cached != null && cached.isNotEmpty) {
      final validEvals = cached
          .where((e) =>
              (e.centipawns != null || e.mate != null) &&
              (e.candidateMove == null ||
                  EngineCache.isMoveColorConsistentWithFen(fen, e.candidateMove!)))
          .map((e) => e.copyWithFen(fen).asWhitePerspective(whiteToMove: whiteToMove))
          .toList();
      if (validEvals.isNotEmpty) {
        setState(() {
          _engineEvalPending = false;
          _engineEvals = validEvals;

          final bfen = _controller.game.bfen;
          if (graph.v[bfen]?.assigned == null && _engineEvals.isNotEmpty) {
            final bestEval = _engineEvals.first;
            final hasFull = bestEval.mate != null ||
                (bestEval.depth != null && bestEval.depth! >= 16);
            if (hasFull) {
              final score = _engineEvalToGraphScore(bestEval, whiteToMove);
              if (score != null) {
                graph.assign(bfen, score);
                graph.v[bfen]?.inDatabase = true;
                graph.solveBfen(bfen);
                _knownMovesToSan();
              }
            }
          }
        });
        final bestCached = validEvals.first;
        final hasFull = bestCached.mate != null ||
            (bestCached.depth != null && bestCached.depth! >= 16);
        if (hasFull) {
          return;
        }
        widget.engineService.startSearch(fen);
        return;
      }
    }

    final shallower = widget.engineService.getCachedEvaluation(fen, minDepth: 0);
    if (shallower != null && shallower.isNotEmpty) {
      final validEvals = shallower
          .where((e) =>
              (e.centipawns != null || e.mate != null) &&
              (e.candidateMove == null ||
                  EngineCache.isMoveColorConsistentWithFen(fen, e.candidateMove!)))
          .map((e) => e.copyWithFen(fen).asWhitePerspective(whiteToMove: whiteToMove))
          .toList();
      if (validEvals.isNotEmpty) {
        setState(() {
          _engineEvalPending = true;
          _engineEvals = validEvals;
        });
        widget.engineService.startSearch(fen);
        return;
      }
    }

    final currentKey = EngineCache.canonicalKey(_variant, fen);
    final isSameFen = _engineEvals.isNotEmpty &&
        _engineEvals.any((e) =>
            e.fen != null && EngineCache.canonicalKey(_variant, e.fen!) == currentKey);

    setState(() {
      _engineEvalPending = true;
      if (!isSameFen) {
        _engineEvals = [];
      }
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
                ? -1
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
    if (_isExploring) return;
    _controller.undoMove();
  }

  void _reset() {
    if (_isExploring) return;
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
    if (mounted) {
      setState(_update);
    }
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
    final stabilizationStopwatch = Stopwatch()..start();
    while (_isExploring &&
        mounted &&
        (_engineEvalPending || _engineEvals.isEmpty)) {
      if (stabilizationStopwatch.elapsedMilliseconds > 3000 && !widget.engineService.isSearching) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    while (_isExploring && mounted) {
      if (_engineEvals.isNotEmpty) {
        final bestEval = _engineEvals.first;
        final bool isCurrentPos = bestEval.fen == null ||
            EngineCache.canonicalKey(_variant, bestEval.fen!) ==
                EngineCache.canonicalKey(_variant, _controller.game.fen);
        if (isCurrentPos &&
            (bestEval.mate != null ||
                (bestEval.depth != null && bestEval.depth! >= 16) ||
                !widget.engineService.isSearching)) {
          break;
        }
      }
      if (stabilizationStopwatch.elapsedMilliseconds > 15000) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (!_isExploring || !mounted) return;

    final knownMoveSans = _getKnownMoveSans();
    final isWhite = _controller.game.turn == white;
    final hasKnownWinningMate = _knownMoves.any((m) =>
        m.eval != null && (isWhite ? m.eval! >= 999.0 : m.eval! <= -999.0));

    // If the side to move already has a winning mate in 1 in known moves, skip exploring weaker alternatives
    if (hasKnownWinningMate) {
      print(
          '[explore] Side to move already has a winning move in graph. Skipping weaker alternatives.');
      return;
    }

    // Check if any candidate move in engine evals is an immediate winning Mate in 1 for the side to move
    String? engineWinningMateSan;
    for (final e in _engineEvals) {
      if (_isWinningMateInOne(e, isWhite)) {
        final san = _uciToSan(e.candidateMove);
        if (san != '—') {
          engineWinningMateSan = san;
          break;
        }
      }
    }

    if (!isRoot) {
      if (knownMoveSans.isEmpty) {
        print(
            '[explore] No branches have been explored from this position. Backing up.');
        return;
      }

      final evaluatedMoveSans = _getEvaluatedMoveSans();

      if (engineWinningMateSan != null &&
          (evaluatedMoveSans.contains(engineWinningMateSan) ||
              evaluatedMoveSans.contains(_controller.game.normalizeMoveString(engineWinningMateSan)))) {
        print(
            '[explore] Winning move ($engineWinningMateSan) already explored from this position. Backing up.');
        return;
      }

      bool hasUnexplored = false;
      if (engineWinningMateSan != null) {
        hasUnexplored = !evaluatedMoveSans.contains(engineWinningMateSan) &&
            !evaluatedMoveSans.contains(_controller.game.normalizeMoveString(engineWinningMateSan));
      } else {
        for (final e in _engineEvals) {
          String san = _uciToSan(e.candidateMove);
          if (san != '—' &&
              !evaluatedMoveSans.contains(san) &&
              !evaluatedMoveSans.contains(_controller.game.normalizeMoveString(san))) {
            hasUnexplored = true;
            break;
          }
        }
        if (!hasUnexplored) {
          for (final m in _knownMoves) {
            if (m.eval == null) {
              hasUnexplored = true;
              break;
            }
          }
        }
      }

      if (!hasUnexplored) {
        print(
            '[explore] All engine moves have been explored from this position. Backing up.');
        return;
      }
    }

    while (_isExploring && mounted) {
      final currentEvaluatedSans = _getEvaluatedMoveSans();
      final currentIsWhite = _controller.game.turn == white;
      final currentHasWinningMate = _knownMoves.any((m) =>
          m.eval != null && (currentIsWhite ? m.eval! >= 999.0 : m.eval! <= -999.0));

      if (currentHasWinningMate) {
        print('[explore] Position resolved with winning move for side to move. Skipping weaker alternatives.');
        break;
      }

      String? nextMoveToExplore;

      // Re-check engine winning mate in 1 in current evals
      String? currentWinningMateSan;
      for (final e in _engineEvals) {
        if (_isWinningMateInOne(e, currentIsWhite)) {
          final san = _uciToSan(e.candidateMove);
          if (san != '—') {
            currentWinningMateSan = san;
            break;
          }
        }
      }

      if (currentWinningMateSan != null) {
        if (currentEvaluatedSans.contains(currentWinningMateSan) ||
            currentEvaluatedSans.contains(_controller.game.normalizeMoveString(currentWinningMateSan))) {
          print(
              '[explore] Winning move ($currentWinningMateSan) already explored. Skipping weaker alternatives.');
          break;
        }
        nextMoveToExplore = currentWinningMateSan;
      } else {
        for (final e in _engineEvals) {
          String san = _uciToSan(e.candidateMove);
          if (san != '—' &&
              !currentEvaluatedSans.contains(san) &&
              !currentEvaluatedSans.contains(_controller.game.normalizeMoveString(san))) {
            nextMoveToExplore = san;
            break;
          }
        }
        if (nextMoveToExplore == null) {
          for (final m in _knownMoves) {
            if (m.eval == null) {
              nextMoveToExplore = m.move;
              break;
            }
          }
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
        if (graph.v[bfen]?.assigned != null || graph.v[bfen]?.computed != null) break;
        if (!widget.engineService.isSearching && _engineEvals.isNotEmpty) break;
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
      await _waitForEngineStabilization();
    }
  }

  Future<void> _waitForEngineStabilization() async {
    final currentFen = _controller.game.fen;
    final currentKey = EngineCache.canonicalKey(_variant, currentFen);
    if (!_engineEvalPending && _engineEvals.isNotEmpty) {
      final bestEval = _engineEvals.first;
      if (bestEval.fen != null &&
          EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey &&
          (bestEval.candidateMove == null ||
              EngineCache.isMoveColorConsistentWithFen(currentFen, bestEval.candidateMove!)) &&
          (bestEval.mate != null ||
              (bestEval.depth != null && bestEval.depth! >= 16) ||
              !widget.engineService.isSearching)) {
        return;
      }
    }
    await Future.delayed(const Duration(milliseconds: 150));
    final stopwatch = Stopwatch()..start();
    while (_isExploring &&
        mounted &&
        (_engineEvalPending || _engineEvals.isEmpty)) {
      if (stopwatch.elapsedMilliseconds > 3000 && !widget.engineService.isSearching) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    while (_isExploring && mounted) {
      if (_engineEvals.isNotEmpty) {
        final bestEval = _engineEvals.first;
        final bool isCurrentPos = bestEval.fen != null &&
            EngineCache.canonicalKey(_variant, bestEval.fen!) ==
                EngineCache.canonicalKey(_variant, _controller.game.fen) &&
            (bestEval.candidateMove == null ||
                EngineCache.isMoveColorConsistentWithFen(_controller.game.fen, bestEval.candidateMove!));
        if (isCurrentPos &&
            (bestEval.mate != null ||
                (bestEval.depth != null && bestEval.depth! >= 16) ||
                !widget.engineService.isSearching)) {
          break;
        }
      }
      if (stopwatch.elapsedMilliseconds > 15000) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> _pickAndAnalyzeGame() async {
    if (_isPickingFile) return;
    setState(() => _isPickingFile = true);

    try {
      const XTypeGroup typeGroup = XTypeGroup(
        label: 'PGN files',
        extensions: <String>['pgn', 'txt'],
      );
      final XFile? file =
          await openFile(acceptedTypeGroups: <XTypeGroup>[typeGroup]);

      // Debounce window to absorb any residual pointer down / up / click events
      // from double-clicking a file in the native file picker.
      await Future.delayed(const Duration(milliseconds: 300));

      if (file != null && mounted) {
        final String pgnText = await file.readAsString();
        if (pgnText.isNotEmpty && mounted) {
          _analyzeGame(pgnText);
        }
      }
    } finally {
      if (mounted) {
        setState(() => _isPickingFile = false);
      }
    }
  }

  Future<void> _analyzeGame(String pgnText) async {
    final games = PgnParser.parse(pgnText);
    if (games.isEmpty || games.every((g) => g.root.children.isEmpty)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to parse PGN or no moves found')),
        );
      }
      return;
    }

    if (!_engineAvailable) return;

    // Reset UI to start position of first chapter before setting _isExploring
    final firstGame = games.first;
    if (firstGame.variant != null) {
      final pgnVar = firstGame.variant!.toLowerCase();
      DatasetVariant? targetVariant;
      for (final v in DatasetVariant.values) {
        if (v.name.toLowerCase() == pgnVar || v.label.toLowerCase() == pgnVar) {
          targetVariant = v;
          break;
        }
      }
      if (targetVariant != null && targetVariant != _variant) {
        await _setVariant(targetVariant);
      }
    }

    if (firstGame.fen != null && firstGame.fen!.isNotEmpty) {
      _controller.load(firstGame.fen!);
    } else {
      _controller.setGame(_createGameForVariant(_variant));
      _controller.resetBoard();
    }
    _update();

    _analyzeTotal = games.fold(0, (sum, g) => sum + 1 + g.root.totalNodes);
    _analyzeProgress = 0;
    _analyzeTimeText = "";
    _analyzeChapterText = "";
    _analyzeStopwatch.reset();
    _analyzeStopwatch.start();

    setState(() {
      _isExploring = true;
      _isAnalyzingGame = true;
    });
    WakelockPlus.enable();
    print('[analyze] Started analyzing study / game(s) with ${games.length} chapter(s) ($_analyzeTotal total positions)');

    try {
      for (int chapterIndex = 0; chapterIndex < games.length; chapterIndex++) {
        if (!_isExploring || !mounted) break;
        final game = games[chapterIndex];
        final chapterTitle = game.chapterName ?? game.event ?? 'Chapter ${chapterIndex + 1}';
        print('[analyze] Starting $chapterTitle');
        setState(() {
          _analyzeChapterText = chapterTitle;
        });

        // Match variant if specified in PGN header
        if (game.variant != null) {
          final pgnVar = game.variant!.toLowerCase();
          DatasetVariant? targetVariant;
          for (final v in DatasetVariant.values) {
            if (v.name.toLowerCase() == pgnVar || v.label.toLowerCase() == pgnVar) {
              targetVariant = v;
              break;
            }
          }
          if (targetVariant != null && targetVariant != _variant) {
            await _setVariant(targetVariant);
          }
        }

        // Set starting position
        if (game.fen != null && game.fen!.isNotEmpty) {
          _controller.load(game.fen!);
        } else {
          _controller.setGame(_createGameForVariant(_variant));
          _controller.resetBoard();
        }
        _update();

        await _waitForEngineStabilization();
        await _analyzePgnTree(game.root);
      }
    } finally {
      _analyzeStopwatch.stop();
      if (mounted) {
        setState(() {
          _isExploring = false;
          _isAnalyzingGame = false;
          _analyzeTimeText = "";
          _analyzeChapterText = "";
          _update();
        });
      }
      WakelockPlus.disable();
      print('[analyze] Game/study analysis ended/stopped.');
    }
  }

  void _recordAnalyzeProgress() {
    _analyzeProgress++;
    final elapsedMs = _analyzeStopwatch.elapsedMilliseconds;
    if (_analyzeProgress > 0 && elapsedMs > 0) {
      final msPerNode = elapsedMs / _analyzeProgress;
      final remainingNodes =
          (_analyzeTotal - _analyzeProgress).clamp(0, _analyzeTotal);
      final remainingMs = (msPerNode * remainingNodes).round();
      final duration = Duration(milliseconds: remainingMs);
      final hours = duration.inHours;
      final minutes = duration.inMinutes % 60;
      final seconds = duration.inSeconds % 60;

      String eta;
      if (hours > 0) {
        eta = "~${hours}h ${minutes}m remaining";
      } else if (minutes > 0) {
        eta = "~${minutes}m ${seconds}s remaining";
      } else {
        eta = "~${seconds}s remaining";
      }
      _analyzeTimeText = "ETA: $eta";
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _analyzePgnTree(PgnNode node) async {
    if (!_isExploring || !mounted) return;

    _recordAnalyzeProgress();

    // Explore/resolve the current position
    await _exploreRecursive(isRoot: true);

    // Recursively traverse each child variation/move
    for (final child in node.children) {
      if (!_isExploring || !mounted) break;
      if (child.san == null) continue;

      print('[analyze] Playing move: ${child.san}');
      final moveSuccess = _controller.makeMoveWithNormalNotation(child.san!);
      if (!moveSuccess) {
        print('[analyze] Warning: Failed to make move ${child.san} from position ${_controller.game.fen}');
        continue;
      }

      await _waitForEngineStabilization();

      // Recurse into child branch
      await _analyzePgnTree(child);

      if (!_isExploring || !mounted) break;

      // Backtrack to parent position
      print('[analyze] Backtracking from move ${child.san}');
      _controller.undoMove();
      await _waitForEngineStabilization();
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

  Set<String> _getEvaluatedMoveSans() {
    final set = <String>{};
    for (final m in _knownMoves) {
      if (m.eval != null) {
        set.add(m.move);
        set.add(_controller.game.normalizeMoveString(m.move));
      }
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
    final currentKey = EngineCache.canonicalKey(_variant, currentFen);
    final validEngineEvals = _engineEvals
        .where((e) =>
            e.fen != null &&
            EngineCache.canonicalKey(_variant, e.fen!) == currentKey &&
            (e.candidateMove == null ||
                EngineCache.isMoveColorConsistentWithFen(currentFen, e.candidateMove!)))
        .toList();

    print('[ENGINE-WIDGET] currentFen="$currentFen" totalEvals=${_engineEvals.length} validEvals=${validEngineEvals.length} candidates=${validEngineEvals.map((e) => "${e.candidateMove} (fen=${e.fen})").toList()}');

    if (validEngineEvals.isEmpty) {
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
      final evaluatedMoveSans = _getEvaluatedMoveSans();
      final rows = validEngineEvals.map((e) {
        String san = _uciToSan(e.candidateMove);
        String evalStr = 'unknown';
        if (e.mate != null) {
          if (e.mate == 0) {
            double? termScore;
            if (e.fen != null) {
              final g = _createGameForVariant(_variant);
              if (g.load(e.fen!)) {
                termScore = g.terminalEvaluation;
              }
            }
            termScore ??= _controller.game.terminalEvaluation;
            if (termScore != null) {
              evalStr = _formatScore(termScore);
            } else {
              evalStr = '+M0';
            }
          } else {
            evalStr = e.mate! > 0 ? '+M${e.mate!}' : '-M${e.mate!.abs()}';
          }
        } else if (e.centipawns != null) {
          final pawns = e.centipawns! / 100.0;
          evalStr = pawns > 0
              ? '+${pawns.toStringAsFixed(2)}'
              : pawns.toStringAsFixed(2);
        }

        final isEvaluated = evaluatedMoveSans.contains(san) ||
            evaluatedMoveSans.contains(_controller.game.normalizeMoveString(san));
        final bool shouldHighlight = !isEvaluated && san != '—';
        return _buildMoveRow(san, evalStr,
            color: shouldHighlight ? Colors.blue : null);
      }).toList();

      content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (depth != null)
                Text('Depth $depth',
                    style: const TextStyle(fontSize: 16, color: Colors.black54)),
              if (_engineEvalPending) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
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
    if (mounted) {
      setState(_update);
    }
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

  /// Converts an [EngineEvaluation] (in White's perspective) to a graph database score (+1000.0 to -1000.0).
  ///
  /// In UCI protocol (evaluated from the perspective of the side to move):
  /// - Standard chess and other checkmate variants (Winner makes the final move):
  ///   - Forced Win in M moves (`score mate +M` where M > 0):
  ///     Plies to mate = 2 * M - 1 (e.g. mate +1 -> 1 ply, mate +2 -> 3 plies, mate +18 -> 35 plies).
  ///   - Forced Loss in M moves (`score mate -M` where M > 0):
  ///     Plies to mate = 2 * M (e.g. mate -1 -> 2 plies, mate -2 -> 4 plies, mate -18 -> 36 plies).
  /// - Antichess / Giveaway (Loser makes the final move):
  ///   - Forced Win in M moves (`score mate +M` where M > 0):
  ///     The side to move gives away pieces and opponent makes the final capture on ply 2*M.
  ///     Plies to mate = 2 * M (e.g. mate +1 -> 2 plies, mate +2 -> 4 plies, mate +18 -> 36 plies).
  ///   - Forced Loss in M moves (`score mate -M` where M > 0):
  ///     The losing side makes the final capture on ply 2*M - 1.
  ///     Plies to mate = 2 * M - 1 (e.g. mate -1 -> 1 ply, mate -2 -> 3 plies, mate -18 -> 35 plies).
  ///
  /// Since [eval] has already been converted to White's perspective via [asWhitePerspective]:
  /// - When [whiteToMove] is true:
  ///   - m > 0: White wins -> side to move is winning
  ///   - m < 0: White loses -> side to move is losing
  /// - When [whiteToMove] is false:
  ///   - m < 0: Black wins -> side to move is winning
  ///   - m > 0: Black loses -> side to move is losing
  double? _engineEvalToGraphScore(EngineEvaluation eval, bool whiteToMove, {DatasetVariant? variant}) {
    variant ??= _variant;
    if (eval.mate != null) {
      final m = eval.mate!;
      if (m == 0) {
        double? termScore;
        if (eval.fen != null) {
          final g = _createGameForVariant(variant);
          if (g.load(eval.fen!)) {
            termScore = g.terminalEvaluation;
          }
        }
        termScore ??= _controller.game.terminalEvaluation;
        return termScore;
      }
      final absM = m.abs();
      final sideToMoveIsWinning = whiteToMove ? (m > 0) : (m < 0);
      final int pliesToMate;
      if (variant == DatasetVariant.antichess) {
        pliesToMate = sideToMoveIsWinning ? (2 * absM) : (2 * absM - 1);
      } else {
        pliesToMate = sideToMoveIsWinning ? (2 * absM - 1) : (2 * absM);
      }
      return m > 0 ? (1000.0 - pliesToMate) : (-1000.0 + pliesToMate);
    } else if (eval.centipawns != null) {
      return eval.centipawns! / 100.0;
    }
    return null;
  }

  bool _isWinningMateInOne(EngineEvaluation eval, bool isWhiteToMove) {
    if (eval.candidateMove == null) return false;
    final score = _engineEvalToGraphScore(eval, isWhiteToMove);
    if (score == null) return false;
    if (_variant == DatasetVariant.antichess) {
      return isWhiteToMove ? score >= 998.0 : score <= -998.0;
    }
    // Immediate mate in 1 on this turn requires +/-999.0 or +/-1000.0 (1 ply to checkmate)
    return isWhiteToMove ? score >= 999.0 : score <= -999.0;
  }

  String _formatScore(double score, {bool wrapInParentheses = false, bool isMoveScore = false}) {
    const double mateThreshold = 900.0;
    String formatted;
    if (score.abs() >= mateThreshold) {
      final sign = score > 0 ? '+' : '-';
      final pliesRemaining = (1000.0 - score.abs()).round();
      int moves;
      if (isMoveScore) {
        final totalPlies = 1 + pliesRemaining;
        moves = (totalPlies + 1) ~/ 2;
      } else {
        if (pliesRemaining == 0) {
          moves = 0;
        } else {
          moves = (pliesRemaining + 1) ~/ 2;
        }
      }
      formatted = '$sign' 'M$moves';
    } else {
      formatted = score > 0 ? '+${score.toStringAsFixed(2)}' : score.toStringAsFixed(2);
    }
    return wrapInParentheses ? '($formatted)' : formatted;
  }

  @visibleForTesting
  double? engineEvalToGraphScore(EngineEvaluation eval, bool whiteToMove, {DatasetVariant? variant}) =>
      _engineEvalToGraphScore(eval, whiteToMove, variant: variant);

  @visibleForTesting
  String formatScore(double score, {bool wrapInParentheses = false, bool isMoveScore = false}) =>
      _formatScore(score, wrapInParentheses: wrapInParentheses, isMoveScore: isMoveScore);

  @visibleForTesting
  Future<void> waitForEngineStabilization() => _waitForEngineStabilization();

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

  @visibleForTesting
  double? parseScore(String text) => _parseScore(text);

  @visibleForTesting
  Set<String> getEvaluatedMoveSans() => _getEvaluatedMoveSans();

  @visibleForTesting
  Set<String> getKnownMoveSans() => _getKnownMoveSans();

  @visibleForTesting
  int Function(MoveInfo, MoveInfo) compareMoves(PlayerColor turn) => _compare(turn);

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
