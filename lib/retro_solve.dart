// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:ui';

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
    this.autoImportGraph = false,
    this.importGraphOverride,
    Key? key,
  }) : super(key: key);

  final DatasetVariant initialVariant;
  final EngineService engineService;
  final bool autoImportGraph;
  final Future<void> Function(String dataPath)? importGraphOverride;

  @override
  Widget build(BuildContext context) {
    var theme = ThemeData(primarySwatch: Colors.deepPurple);
    return MaterialApp(
      title: 'Retro Solve',
      theme: theme,
      home: HomePage(
        initialVariant: initialVariant,
        engineService: engineService,
        autoImportGraph: autoImportGraph,
        importGraphOverride: importGraphOverride,
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({
    required this.initialVariant,
    required this.engineService,
    this.autoImportGraph = false,
    this.importGraphOverride,
    Key? key,
  }) : super(key: key);

  final DatasetVariant initialVariant;
  final EngineService engineService;
  final bool autoImportGraph;
  final Future<void> Function(String dataPath)? importGraphOverride;

  @override
  HomePageState createState() => HomePageState();
}

enum _MoreAction { solve, mateSolver, export_, analyzeGame, exploreHistory, explore1Ply, copyFen, copyMoveHistory, toggleBacksolve, toggleTablebase, toggleAutosolveAfterExplore }

class HomePageState extends State<HomePage> with WidgetsBindingObserver {
  StreamSubscription<List<EngineEvaluation>>? _evalSub;
  Timer? _evalTimer;
  List<EngineEvaluation>? _pendingEvals;
  bool _interactiveBacksolving = true;
  bool _enableTablebase = Config.enableRemoteTablebase;
  bool _autosolveAfterExplore = false;

  @visibleForTesting
  bool get interactiveBacksolving => _interactiveBacksolving;

  @visibleForTesting
  void setInteractiveBacksolvingForTesting(bool value) =>
      _toggleInteractiveBacksolving(value);

  @visibleForTesting
  bool get autosolveAfterExplore => _autosolveAfterExplore;

  @visibleForTesting
  void setAutosolveAfterExploreForTesting(bool value) =>
      _toggleAutosolveAfterExplore(value);

  @visibleForTesting
  bool get isExploring1Ply => _isExploring1Ply;

  @visibleForTesting
  Future<void> startExploring1Ply() => _startExploring1Ply();

  @visibleForTesting
  bool get isExploringHistory => _isExploringHistory;

  @visibleForTesting
  Future<void> startExploringHistory() => _startExploringHistory();

  @visibleForTesting
  String get mateSolverTitle => _mateSolverTitle;

  @visibleForTesting
  MateSolverResult? get mateSolverResult => _mateSolverResult;

  @visibleForTesting
  void jumpToFailurePoint() => _jumpToFailurePoint();

  @visibleForTesting
  void returnToStartPoint() => _returnToStartPoint();

  @visibleForTesting
  int get mateSolverNodesCount => _mateSolverNodesCount;

  @visibleForTesting
  bool get isMateSolving => _isMateSolving;

  @visibleForTesting
  Future<bool> startMateSolver({int maxDepth = 20, PlayerColor? attackingColor}) =>
      _startMateSolver(maxDepth: maxDepth, attackingColor: attackingColor);

  @visibleForTesting
  void stopMateSolver() => _stopMateSolver();

  @visibleForTesting
  Future<void> solveForTesting() => _solve();

  @visibleForTesting
  void setSolvingForTesting(bool value, {double progress = 0.0, String status = ''}) {
    setState(() {
      _isSolving = value;
      _solveProgress = progress;
      _solveStatus = status;
    });
  }

  void _toggleInteractiveBacksolving(bool value) {
    setState(() {
      _interactiveBacksolving = value;
    });
    InteractiveBacksolvingStore.save(value);
  }

  void _toggleAutosolveAfterExplore(bool value) {
    setState(() {
      _autosolveAfterExplore = value;
    });
    AutosolveAfterExploreStore.save(value);
  }



  @override
  Widget build(BuildContext context) {
    final bool isBoardDisabled =
        _isExploring || _isAnalyzingGame || _isExploringHistory || _isBatchEvaluating || _isLoadingVariant || _isPickingFile || _isSolving || _isMateSolving;

    final lastMove = _controller.game.history.isNotEmpty ? _controller.game.history.last.move : null;
    final lastMoveFrom = lastMove?.fromAlgebraic;
    final lastMoveTo = lastMove?.toAlgebraic;

    var chessboard = IgnorePointer(
      ignoring: isBoardDisabled,
      child: ChessBoard(
        controller: _controller,
        boardColor: BoardColor.brown,
        boardOrientation: _orientation,
        enableUserMoves: !isBoardDisabled,
        lastMoveFrom: lastMoveFrom,
        lastMoveTo: lastMoveTo,
      ),
    );
    var turn = Text(_turn, style: _textStyle);
    var appBar = AppBar(
      title: _isSolving
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('RetroSolve'),
                const SizedBox(width: 8),
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                ),
                if (_solveStatus.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      _solveStatus,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.normal,
                        color: Colors.white70,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            )
          : const Text('RetroSolve'),
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
      itemBuilder: (_) => [
        PopupMenuItem(
          value: _MoreAction.solve,
          enabled: !_isSolving && !_isMateSolving,
          child: Row(
            children: [
              const Text('Solve'),
              if (_isSolving) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        PopupMenuItem(
          value: _MoreAction.mateSolver,
          enabled: !_isSolving && !_isExploring && !_isExploringHistory && !_isAnalyzingGame,
          child: Row(
            children: [
              Text(_isMateSolving ? 'Stop Mate Solver' : 'Mate Solver'),
              if (_isMateSolving) ...[
                const SizedBox(width: 8),
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
        ),
        const PopupMenuItem(
          value: _MoreAction.export_,
          child: Text('Export'),
        ),
        const PopupMenuItem(
          value: _MoreAction.analyzeGame,
          child: Text('Analyze Game'),
        ),
        PopupMenuItem(
          value: _MoreAction.exploreHistory,
          enabled: !isBoardDisabled,
          child: const Text('Explore move history'),
        ),
        PopupMenuItem(
          value: _MoreAction.explore1Ply,
          enabled: !isBoardDisabled,
          child: const Text('Explore legal moves (1-ply)'),
        ),
        const PopupMenuItem(
          value: _MoreAction.copyFen,
          child: Text('Copy FEN to clipboard'),
        ),
        const PopupMenuItem(
          value: _MoreAction.copyMoveHistory,
          child: Text('Copy move history to clipboard'),
        ),
        const PopupMenuDivider(),
        CheckedPopupMenuItem<_MoreAction>(
          value: _MoreAction.toggleBacksolve,
          checked: _interactiveBacksolving,
          child: const Text('Interactive Backsolving'),
        ),
        CheckedPopupMenuItem<_MoreAction>(
          value: _MoreAction.toggleTablebase,
          checked: _enableTablebase,
          child: const Text('Online Tablebase (DTW)'),
        ),
        CheckedPopupMenuItem<_MoreAction>(
          value: _MoreAction.toggleAutosolveAfterExplore,
          checked: _autosolveAfterExplore,
          child: const Text('Auto-solve after explore'),
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
        _button(_isExploring && !_isExploring1Ply ? "stop exploring" : "explore",
            (_isPickingFile || _isExploring1Ply || _isMateSolving || ((_isAnalyzingGame || _isExploringHistory) && !_isExploring)) ? null : _exploreToggle),
        _button(_isExploring1Ply ? "stop 1-ply" : "explore 1-ply",
            (_isPickingFile || _isAnalyzingGame || _isExploringHistory || _isMateSolving || (_isExploring && !_isExploring1Ply))
                ? null
                : _explore1PlyToggle),
        if (_isMateSolving)
          _button("stop mate", _stopMateSolver),
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
                    _evaluationWidget(width: 280),
                    _engineWidget(width: 280),
                  ],
                ),
                if (_isAnalyzingGame || _isExploringHistory) ...[
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
                const SizedBox(height: 16),
                _moveHistoryWidget(width: (constraints.maxWidth - 24).clamp(280.0, 572.0)),
                if (_isSolving) ...[
                  const SizedBox(height: 12),
                  _solveProgressWidget(width: (constraints.maxWidth - 24).clamp(280.0, 572.0)),
                ],
                if (_isMateSolving || _mateSolverResult != null) ...[
                  const SizedBox(height: 12),
                  _mateSolverCard(width: (constraints.maxWidth - 24).clamp(280.0, 572.0)),
                ],
                const SizedBox(height: 32),
              ],
            ),
          );
        }

                final double columnWidth = constraints.maxWidth >= 1100
                    ? 340.0
                    : (constraints.maxWidth >= 950 ? 310.0 : 280.0);
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
                          width: columnWidth * 2 + 16,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              SizedBox(
                                height: _maxKnownMovesHeight + 92.0,
                                child: Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    SizedBox(
                                      width: columnWidth,
                                      child: _movesColumn(columnWidth),
                                    ),
                                    const SizedBox(width: 16),
                                    SizedBox(
                                      width: columnWidth,
                                      child: _engineColumn(columnWidth),
                                    ),
                                  ],
                                ),
                              ),
                              Expanded(
                                child: SingleChildScrollView(
                                  child: _padded(
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        _moveHistoryWidget(width: columnWidth * 2),
                                        if (_isSolving) ...[
                                          const SizedBox(height: 12),
                                          _solveProgressWidget(width: columnWidth * 2),
                                        ],
                                        if (_isMateSolving || _mateSolverResult != null) ...[
                                          const SizedBox(height: 12),
                                          _mateSolverCard(width: columnWidth * 2),
                                        ],
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
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
            ColoredBox(
              color: const Color(0x66000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    if (_loadingMessage != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _loadingMessage!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
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
  String? _loadingMessage;
  List<MoveInfo> _knownMoves = [];
  String _bfen = "";
  String _eval = "";
  List<EngineEvaluation> _engineEvals = [];
  bool _engineAvailable = false;
  bool _engineEvalPending = false;
  String _turn = "";
  PlayerColor _orientation = white;
  final TextEditingController _evalController = TextEditingController();
  final ScrollController _knownMovesScrollController = ScrollController();
  @visibleForTesting
  ScrollController get knownMovesScrollController => _knownMovesScrollController;

  bool _isBatchEvaluating = false;
  bool _isExploring = false;
  bool _isExploring1Ply = false;
  bool _isExploringHistory = false;
  bool _isMateSolving = false;
  String _mateSolverTitle = "";
  String _mateSolverStatus = "";
  int _mateSolverNodesCount = 0;
  MateSolverResult? _mateSolverResult;
  int _evalProgress = 0;
  int _evalTotal = 0;
  String _batchTimeText = "";

  bool _isSolving = false;
  double _solveProgress = 0.0;
  String _solveStatus = "";
  @visibleForTesting
  bool get isSolving => _isSolving;

  bool _isAnalyzingGame = false;
  bool _isPickingFile = false;
  int _analyzeProgress = 0;
  int _analyzeTotal = 0;
  String _analyzeTimeText = "";
  String _analyzeChapterText = "";
  final Stopwatch _analyzeStopwatch = Stopwatch();

  @visibleForTesting
  String formatMoveWithNumber(String move) {
    if (move.isEmpty || move == '—') return move;
    if (RegExp(r'^\d+\.{1,3}\s*').hasMatch(move)) return move;
    final isWhite = _controller.game.turn == white;
    final num = _controller.game.moveNumber;
    return isWhite ? '$num. $move' : '$num... $move';
  }

  TableRow _buildMoveRow(String move, String evalStr, {Color? color}) {
    final displayText = formatMoveWithNumber(move);
    return TableRow(
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, right: 20.0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 0),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                alignment: Alignment.centerLeft,
              ),
              onPressed: _isExploring || move == '—'
                  ? null
                  : () => _controller.makeMoveWithNormalNotation(move),
              child: Text(displayText,
                  softWrap: false,
                  maxLines: 1,
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold, color: color)),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 8.0, right: 12.0),
          child: Text(
            evalStr,
            softWrap: false,
            maxLines: 1,
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

  static const int _maxVisibleKnownMoves = 8;
  static const double _moveRowHeight = 37.0;
  static const double _maxKnownMovesHeight = _maxVisibleKnownMoves * _moveRowHeight;

  Widget _movesTable() {
    var rows = _knownMoves.map((MoveInfo info) {
      String evalStr = "";
      if (info.eval != null) {
        evalStr = info.eval!.format(isMove: true);
      }
      return _buildMoveRow(info.move, evalStr);
    }).toList();

    return _padded(
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: _maxKnownMovesHeight),
        child: Scrollbar(
          controller: _knownMovesScrollController,
          thumbVisibility: _knownMoves.length > _maxVisibleKnownMoves ? true : null,
          child: SingleChildScrollView(
            controller: _knownMovesScrollController,
            padding: const EdgeInsets.only(right: 16.0),
            child: Table(
              columnWidths: const <int, TableColumnWidth>{
                0: IntrinsicColumnWidth(),
                1: IntrinsicColumnWidth(),
              },
              children: rows,
              defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            ),
          ),
        ),
      ),
    );
  }

  Widget _movesColumn([double? width]) {
    final widgetWidth = (width != null ? width - 16 : 280.0).clamp(240.0, 340.0);
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _evaluationWidget(width: widgetWidth),
          Flexible(
            child: _movesTable(),
          ),
        ],
      ),
    );
  }

  Widget _solveProgressWidget({double? width}) {
    final percent = _solveProgress.clamp(0.0, 1.0);
    return Container(
      width: width ?? double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepPurple.shade200),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple.shade700),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _solveStatus.isNotEmpty ? _solveStatus : "Solving graph...",
                  style: TextStyle(
                    fontSize: 13,
                    color: Colors.deepPurple.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: percent > 0 ? percent : null,
              minHeight: 6,
              backgroundColor: Colors.deepPurple.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple.shade600),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      final hours = d.inHours;
      final minutes = d.inMinutes % 60;
      final seconds = d.inSeconds % 60;
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (d.inMinutes > 0) {
      final minutes = d.inMinutes;
      final seconds = d.inSeconds % 60;
      return '${minutes}m ${seconds}s';
    } else {
      return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
    }
  }

  Widget _mateSolverCard({double? width}) {
    if (_isMateSolving) {
      return _mateSolverProgressWidget(width: width);
    } else if (_mateSolverResult != null) {
      return _mateSolverResultWidget(width: width);
    }
    return const SizedBox.shrink();
  }

  Widget _mateSolverResultWidget({double? width}) {
    if (_mateSolverResult == null) return const SizedBox.shrink();
    final result = _mateSolverResult!;

    final Color bgColor;
    final Color borderColor;
    final Color primaryColor;
    final IconData icon;

    if (result.proven) {
      bgColor = Colors.green.shade50;
      borderColor = Colors.green.shade300;
      primaryColor = Colors.green.shade900;
      icon = Icons.check_circle_outline;
    } else if (result.stopped) {
      bgColor = Colors.grey.shade100;
      borderColor = Colors.grey.shade400;
      primaryColor = Colors.grey.shade900;
      icon = Icons.stop_circle_outlined;
    } else {
      bgColor = Colors.amber.shade50;
      borderColor = Colors.amber.shade400;
      primaryColor = Colors.brown.shade900;
      icon = Icons.error_outline;
    }

    return Container(
      width: width ?? double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: primaryColor, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  result.title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: primaryColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  result.message,
                  style: TextStyle(
                    fontSize: 13,
                    color: primaryColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Nodes explored: ${result.nodes} • Time: ${_formatDuration(result.elapsed)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: primaryColor.withValues(alpha: 0.85),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (!result.proven && result.failureMoves != null && result.failureMoves!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Builder(
                    builder: (context) {
                      final isAtFailure =
                          result.failureBfen != null && _controller.game.bfen == result.failureBfen;
                      return OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: primaryColor,
                          side: BorderSide(color: primaryColor.withValues(alpha: 0.5)),
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          minimumSize: const Size(0, 28),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: Icon(
                          isAtFailure ? Icons.replay : Icons.arrow_forward,
                          size: 14,
                        ),
                        label: Text(
                          isAtFailure
                              ? 'Return to start'
                              : 'Jump to failure (${result.failureMoves!.length} ${result.failureMoves!.length == 1 ? 'ply' : 'plies'})',
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                        onPressed: isAtFailure ? _returnToStartPoint : _jumpToFailurePoint,
                      );
                    },
                  ),
                ],
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            color: primaryColor,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: 'Dismiss',
            onPressed: () {
              setState(() {
                _mateSolverResult = null;
              });
            },
          ),
        ],
      ),
    );
  }

  void _jumpToFailurePoint() {
    final result = _mateSolverResult;
    if (result == null || result.failureMoves == null || result.failureMoves!.isEmpty) return;

    if (result.rootBfen != null) {
      while (_controller.game.bfen != result.rootBfen && _controller.game.history.isNotEmpty) {
        _controller.undoMove();
      }
      if (_controller.game.bfen != result.rootBfen && result.rootFen != null) {
        _controller.load(result.rootFen!);
      }
    }

    for (final move in result.failureMoves!) {
      final san = _controller.game.moveToSan(move);
      final success = _controller.makeMoveWithNormalNotation(san);
      if (!success) {
        if (move.promotion != null) {
          _controller.makeMoveWithPromotion(
            from: move.fromAlgebraic,
            to: move.toAlgebraic,
            pieceToPromoteTo: move.promotion!.name.toUpperCase(),
          );
        } else {
          _controller.makeMove(
            from: move.fromAlgebraic,
            to: move.toAlgebraic,
          );
        }
      }
    }

    if (result.failureFen != null && _controller.game.fen != result.failureFen) {
      _controller.load(result.failureFen!);
    }

    if (mounted) {
      setState(_update);
      _requestEngineEval();
    }
  }

  void _returnToStartPoint() {
    final result = _mateSolverResult;
    if (result == null || result.rootBfen == null) return;

    while (_controller.game.bfen != result.rootBfen && _controller.game.history.isNotEmpty) {
      _controller.undoMove();
    }
    if (_controller.game.bfen != result.rootBfen && result.rootFen != null) {
      _controller.load(result.rootFen!);
    }

    if (mounted) {
      setState(_update);
      _requestEngineEval();
    }
  }

  Widget _mateSolverProgressWidget({double? width}) {
    return Container(
      width: width ?? double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      margin: const EdgeInsets.only(bottom: 8.0),
      decoration: BoxDecoration(
        color: Colors.deepPurple.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.deepPurple.shade200),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.deepPurple.shade700),
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _mateSolverTitle.isNotEmpty ? _mateSolverTitle : "Searching for forced mate...",
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.deepPurple.shade900,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
          if (_mateSolverStatus.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              _mateSolverStatus,
              style: TextStyle(
                fontSize: 14,
                color: Colors.deepPurple.shade900,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
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

  _engineColumn([double? width]) {
    final widgetWidth = (width != null ? width - 16 : 280.0).clamp(240.0, 340.0);
    return _padded(
      Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (_isAnalyzingGame || _isExploringHistory)
            _analyzeGameProgress(),
          if (Config.showBatchEval && _isBatchEvaluating)
            _batchEvalProgress(),
          Expanded(
            child: SingleChildScrollView(
              child: _engineWidget(width: widgetWidth),
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
    WidgetsBinding.instance.addObserver(this);
    _variant = widget.initialVariant;
    _controller.setGame(_createGameForVariant(_variant));
    _controller.game.reset();
    _engineAvailable = widget.engineService.isEngineAvailable;
    if (widget.autoImportGraph) {
      _isLoadingVariant = true;
      _loadingMessage = 'Loading database...';
      _initStartup();
    }
    InteractiveBacksolvingStore.load().then((val) {
      if (mounted) setState(() => _interactiveBacksolving = val);
    });
    TablebaseStore.load().then((val) {
      if (mounted) {
        setState(() {
          _enableTablebase = val;
          Config.enableRemoteTablebase = val;
        });
      }
    });
    AutosolveAfterExploreStore.load().then((val) {
      if (mounted) setState(() => _autosolveAfterExplore = val);
    });
    _evalSub = widget.engineService.evaluationStream.listen((evals) {
      if (!mounted || _isBatchEvaluating) return;
      _pendingEvals = evals;
      if (_evalTimer == null || !_evalTimer!.isActive) {
        _evalTimer = Timer(const Duration(milliseconds: 150), () async {
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
          });

          // Auto-populate node directly if not in database and depth is sufficient
          if (_isExploring || _isAnalyzingGame || _isBatchEvaluating) return;
          final bfen = _controller.game.bfen;
          final existingAssigned = graph.v[bfen]?.assigned;
          if (_engineEvals.isNotEmpty) {
            final bestEval = _engineEvals.first;
            final bool isSufficient = bestEval.dtw != null ||
                bestEval.mate != null ||
                bestEval.isPseudoMate ||
                (bestEval.depth != null && bestEval.depth! >= 16) ||
                (!widget.engineService.isSearching &&
                    bestEval.depth != null);
            if (bestEval.fen != null &&
                EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey &&
                isSufficient) {
              final posEval = _engineEvalToPositionEval(bestEval, _controller.game.turn == white);
              if (posEval != null) {
                // DTW overrides engine eval:
                // Only assign if node has no assigned eval, or if new eval has DTW and existing lacks DTW
                final canAssign = existingAssigned == null ||
                    (posEval.dtw != null && existingAssigned.dtw == null);
                if (canAssign) {
                  graph.assign(bfen, posEval);
                  graph.v[bfen]?.inDatabase = true;
                if (_interactiveBacksolving) {
                  if (graph is CachedGraph) {
                    await (graph as CachedGraph).solveBfenAsync(bfen);
                  } else {
                    graph.solveBfen(bfen);
                  }
                }
                if (mounted && _controller.game.bfen == bfen) {
                  setState(() {
                    _knownMovesToSan();
                    final assigned = graph.v[bfen]?.assigned;
                    final computed = graph.v[bfen]?.computed;
                    if (computed != null) {
                      final bool isSameAsAssigned = assigned != null && computed == assigned;
                      _eval = isSameAsAssigned
                          ? assigned.format()
                          : '(${computed.format()})';
                    } else if (assigned != null) {
                      _eval = assigned.format();
                    }
                    if (_evalController.text != _eval) {
                      _evalController.text = _eval;
                    }
                  });
                }
              }
            }
          }
        }
      });
    }
  });
    _update();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _knownMovesScrollController.dispose();
    _evalController.dispose();
    _evalTimer?.cancel();
    _evalSub?.cancel();
    widget.engineService.dispose();
    TablebaseService.instance.unregisterClient();
    super.dispose();
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    await TablebaseService.instance.unregisterClient();
    return AppExitResponse.exit;
  }

  Future<void> _initStartup() async {
    // Let the loading overlay paint before starting background tasks
    await Future<void>.delayed(const Duration(milliseconds: 16));
    if (!mounted) return;

    // Start engine concurrently in background
    widget.engineService.start().then((_) {
      if (mounted) {
        setState(() {
          _engineAvailable = widget.engineService.isEngineAvailable;
        });
        if (!_isLoadingVariant) {
          _update();
        }
      }
    }).catchError((e, st) {
      print('[RetroSolve] Error starting engine: $e\n$st');
    });

    // Ensure tablebase sidecar server is running concurrently in background if enabled
    if (TablebaseService.instance.isLocalEnabled &&
        Config.autoLaunchTablebaseServer) {
      TablebaseService.instance.ensureServerRunning().then((ready) {
        if (ready && mounted) {
          print(
              '[tablebase] Sidecar server ready and registered (client: ${TablebaseService.instance.clientId})');
        }
      }).catchError((e, st) {
        print('[tablebase] Error ensuring tablebase server: $e\n$st');
      });
    }

    try {
      graph.onNodeUpdated = (bfen, assigned, computed) {
        DatabaseService.instance.upsertNode(bfen, assigned, computed);
      };
      graph.onEdgeAdded = (source, target) {
        DatabaseService.instance.upsertEdge(source, target);
      };
      if (widget.importGraphOverride != null) {
        await widget.importGraphOverride!(_variant.dataPath);
      } else {
        await importGraph(_variant.dataPath);
      }
    } catch (e, st) {
      print('[RetroSolve] Error importing graph on startup: $e\n$st');
    } finally {
      if (mounted) {
        setState(() {
          _isLoadingVariant = false;
          _loadingMessage = null;
          _engineAvailable = widget.engineService.isEngineAvailable;
          _update();
        });
        _chessBoardListener();
      }
    }
  }

  Future<void> _setVariant(DatasetVariant? v) async {
    if (v == null) return;
    if (v == _variant) return;

    setState(() {
      _variant = v;
      _isLoadingVariant = true;
      _loadingMessage = 'Loading ${v.label}...';
    });

    _controller.removeListener(_chessBoardListener);

    try {
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

      if (widget.importGraphOverride != null) {
        await widget.importGraphOverride!(_variant.dataPath);
      } else {
        await importGraph(_variant.dataPath);
      }
      await DatasetVariantStore.save(_variant);
    } catch (e, st) {
      print('[RetroSolve] Error switching variant to $v: $e\n$st');
    } finally {
      _controller.addListener(_chessBoardListener);
      if (mounted) {
        setState(() {
          _isLoadingVariant = false;
          _loadingMessage = null;
          _update();
        });
        _chessBoardListener();
      }
    }
  }

  int _chessBoardListenerSeq = 0;

  void _chessBoardListener() async {
    if (_isLoadingVariant) return;
    final seq = ++_chessBoardListenerSeq;
    var game = _controller.game.copy();
    String a = game.bfen;

    List<Move> moves = game.generateMoves();
    final childBfens = <String>[];
    for (var move in moves) {
      game.makeMove(move);
      childBfens.add(game.bfen);
      game.undo();
    }

    if (graph is CachedGraph) {
      await (graph as CachedGraph).prefetchPositions([a, ...childBfens]);
    }

    if (!mounted || seq != _chessBoardListenerSeq) return;

    if (game.gameOver) {
      final score = game.terminalEvaluation;
      if (score != null && graph.v[a]?.assigned == null) {
        graph.assign(a, score);
      }
      if (mounted && seq == _chessBoardListenerSeq) {
        setState(_update);
      }
      if (_interactiveBacksolving && !_isExploring && !_isAnalyzingGame) {
        if (graph is CachedGraph) {
          (graph as CachedGraph).solveBfenAsync(a).then((_) {
            if (mounted && seq == _chessBoardListenerSeq) setState(_update);
          });
        } else {
          graph.solveBfen(a);
          if (mounted && seq == _chessBoardListenerSeq) setState(_update);
        }
      }
      return;
    }

    bool hasNewTerminalAssignment = false;
    for (int i = 0; i < moves.length; i++) {
      final move = moves[i];
      final b = childBfens[i];
      game.makeMove(move);
      if (game.gameOver) {
        final score = game.terminalEvaluation;
        if (score != null && graph.v[b]?.assigned == null) {
          graph.assign(b, score);
          hasNewTerminalAssignment = true;
        }
      }
      game.undo();
      graph.addLink(a, b);
    }

    // Immediately render board position, known moves table, and current eval
    if (mounted && seq == _chessBoardListenerSeq) {
      setState(_update);
    }

    // Backsolve asynchronously in background only when needed without blocking navigation
    if (_interactiveBacksolving && !_isExploring && !_isAnalyzingGame) {
      if (graph is CachedGraph) {
        (graph as CachedGraph).solveBfenAsync(a).then((_) {
          if (mounted && seq == _chessBoardListenerSeq) setState(_update);
        });
      } else {
        final needsSolve = hasNewTerminalAssignment || graph.v[a]?.effectiveEval == null;
        if (needsSolve) {
          graph.solveBfen(a);
          if (mounted && seq == _chessBoardListenerSeq) setState(_update);
        }
      }
    }
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
    final vertex = graph.v[_bfen];
    if (vertex != null) {
      final assigned = vertex.assigned;
      final computed = vertex.computed;
      if (computed != null) {
        final bool isSameAsAssigned = assigned != null && computed == assigned;
        _eval = isSameAsAssigned
            ? assigned.format()
            : '(${computed.format()})';
      } else if (assigned != null) {
        _eval = assigned.format();
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
          final existingAssigned = graph.v[bfen]?.assigned;
          if (_engineEvals.isNotEmpty) {
            final bestEval = _engineEvals.first;
            final hasFull = bestEval.dtw != null ||
                bestEval.mate != null ||
                bestEval.isPseudoMate ||
                (bestEval.depth != null &&
                    bestEval.depth! >= 16);
            if (hasFull) {
              final posEval = _engineEvalToPositionEval(bestEval, whiteToMove);
              final canAssign = existingAssigned == null ||
                  (posEval?.dtw != null && existingAssigned.dtw == null);
              if (posEval != null && canAssign) {
                graph.assign(bfen, posEval);
                graph.v[bfen]?.inDatabase = true;
                if (_interactiveBacksolving) {
                  if (graph is CachedGraph) {
                    (graph as CachedGraph).solveBfenAsync(bfen).then((_) {
                      if (mounted) setState(_update);
                    });
                  } else {
                    graph.solveBfen(bfen);
                    _knownMovesToSan();
                  }
                } else {
                  _knownMovesToSan();
                }
              }
            }
          }
        });
        final bestCached = validEvals.first;
        final hasFull = bestCached.dtw != null ||
            bestCached.mate != null ||
            bestCached.isPseudoMate ||
            (bestCached.depth != null &&
                bestCached.depth! >= 16);
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
        return PositionEval.compare(i.eval, j.eval, turn == white);
      };

  void _knownMovesToSan() {
    _knownMoves = [];
    _controller.getPossibleMoves().forEach(_addMoveIfKnown);
    _knownMoves.sort(_compare(_controller.game.turn));
    print('[KNOWN-MOVES] bfen="${_controller.game.bfen}" count=${_knownMoves.length} moves=${_knownMoves.map((m) => "${m.move} (${m.eval})").toList()}');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_knownMovesScrollController.hasClients) {
        _knownMovesScrollController.jumpTo(0);
      }
    });
  }

  void _addMoveIfKnown(Move move) {
    var game = _controller.game.copy();
    var scratch = game.copy();
    scratch.makeMove(move);
    var vertex = graph.v[scratch.bfen];
    if (vertex == null) return;
    if (vertex.effectiveEval == null && vertex.links.isEmpty) return;
    _knownMoves.add(MoveInfo(game.moveToSan(move), vertex.effectiveEval));
  }

  void _back() {
    if (_isExploring) return;
    _controller.undoMove();
  }

  void _reset() {
    if (_isExploring || _isMateSolving) return;
    setState(() {
      _mateSolverResult = null;
    });
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

  Future<void> _solve() async {
    if (_isSolving) return;
    setState(() {
      _isSolving = true;
      _solveProgress = 0.0;
      _solveStatus = 'Solving graph...';
    });
    try {
      if (graph is CachedGraph) {
        await (graph as CachedGraph).solveGlobal(
          onProgress: (progress, status) {
            if (mounted) {
              setState(() {
                _solveProgress = progress;
                _solveStatus = status;
              });
            }
          },
        );
      } else {
        graph.solve();
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSolving = false;
          _solveProgress = 0.0;
          _solveStatus = '';
          _update();
        });
      }
    }
  }

  void _onMoreAction(_MoreAction action) {
    switch (action) {
      case _MoreAction.solve:
        _solve();
        break;
      case _MoreAction.mateSolver:
        if (_isMateSolving) {
          _stopMateSolver();
        } else {
          _startMateSolver();
        }
        break;
      case _MoreAction.export_:
        _export();
        break;
      case _MoreAction.analyzeGame:
        _pickAndAnalyzeGame();
        break;
      case _MoreAction.exploreHistory:
        _startExploringHistory();
        break;
      case _MoreAction.toggleBacksolve:
        _toggleInteractiveBacksolving(!_interactiveBacksolving);
        break;
      case _MoreAction.toggleTablebase:
        setState(() {
          _enableTablebase = !_enableTablebase;
          Config.enableRemoteTablebase = _enableTablebase;
          TablebaseStore.save(_enableTablebase);
        });
        break;
      case _MoreAction.toggleAutosolveAfterExplore:
        _toggleAutosolveAfterExplore(!_autosolveAfterExplore);
        break;
      case _MoreAction.explore1Ply:
        _explore1PlyToggle();
        break;
      case _MoreAction.copyFen:
        _copyFenToClipboard();
        break;
      case _MoreAction.copyMoveHistory:
        _copyMoveHistoryToClipboard();
        break;
    }
  }


  void _copyMoveHistoryToClipboard() {
    final history = formatMoveHistory();
    if (history.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No move history to copy'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    Clipboard.setData(ClipboardData(text: history));
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Move history copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _copyFenToClipboard() {
    final fen = _controller.game.fen;
    Clipboard.setData(ClipboardData(text: fen));
    if (mounted) {
      ScaffoldMessenger.of(context).hideCurrentSnackBar();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('FEN copied to clipboard'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  void _exploreToggle() {
    if (_isExploring) {
      setState(() => _isExploring = false);
    } else if (!_isAnalyzingGame && !_isExploringHistory) {
      _startExploring();
    }
  }

  Future<void> _startExploring() async {
    if (!_engineAvailable) return;
    setState(() => _isExploring = true);
    WakelockPlus.enable();
    print('[explore] Started exploring');

    final rootBfen = _controller.game.bfen;

    try {
      await _exploreRecursive(isRoot: true);
    } finally {
      WakelockPlus.disable();

      while (_controller.game.bfen != rootBfen && _controller.game.history.isNotEmpty) {
        _controller.undoMove();
      }

      if (_interactiveBacksolving) {
        if (graph is CachedGraph) {
          await (graph as CachedGraph).solveBfenAsync(rootBfen);
        } else {
          graph.solveBfen(rootBfen);
        }
      }
      if (_autosolveAfterExplore) {
        await _solve();
      }

      if (mounted) {
        setState(() {
          _isExploring = false;
          _update();
        });
      }
      print('[explore] Exploration ended/stopped.');
    }
  }

  Future<void> _ensureCurrentPositionLinked() async {
    final game = _controller.game.copy();
    final a = game.bfen;

    final moves = game.generateMoves();
    final childBfens = <String>[];
    for (final move in moves) {
      game.makeMove(move);
      childBfens.add(game.bfen);
      game.undo();
    }

    if (graph is CachedGraph) {
      await (graph as CachedGraph).prefetchPositions([a, ...childBfens]);
    }

    if (game.gameOver) {
      final score = game.terminalEvaluation;
      if (score != null && graph.v[a]?.assigned == null) {
        graph.assign(a, score);
      }
      return;
    }

    for (int i = 0; i < moves.length; i++) {
      final move = moves[i];
      final b = childBfens[i];
      game.makeMove(move);
      if (game.gameOver) {
        final score = game.terminalEvaluation;
        if (score != null && graph.v[b]?.assigned == null) {
          graph.assign(b, score);
        }
      }
      game.undo();
      graph.addLink(a, b);
    }
  }

  Future<void> _startExploringHistory() async {
    if (!_engineAvailable ||
        _isExploring ||
        _isSolving ||
        _isAnalyzingGame ||
        _isExploringHistory ||
        _isBatchEvaluating) {
      return;
    }

    final savedGame = _controller.game.copy();
    final savedBfen = savedGame.bfen;

    _analyzeTotal = _controller.game.history.length + 1;
    _analyzeProgress = 0;
    _analyzeTimeText = "";
    _analyzeChapterText = "Exploring move history";
    _analyzeStopwatch.reset();
    _analyzeStopwatch.start();

    setState(() {
      _isExploring = true;
      _isExploringHistory = true;
    });
    WakelockPlus.enable();
    print('[explore-history] Started exploring move history ($_analyzeTotal positions)');

    try {
      while (_isExploring && mounted) {
        _recordAnalyzeProgress();

        final targetHistoryLen = _controller.game.history.length;
        final stepBfen = _controller.game.bfen;

        await _ensureCurrentPositionLinked();
        if (!mounted || !_isExploring) break;
        setState(_update);

        await _waitForEngineStabilization();
        if (!mounted || !_isExploring) break;

        if (graph.v[stepBfen]?.assigned == null && _engineEvals.isNotEmpty) {
          final bestEval = _engineEvals.first;
          final currentFen = _controller.game.fen;
          final currentKey = EngineCache.canonicalKey(_variant, currentFen);
          if (bestEval.fen != null &&
              EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey) {
            final posEval =
                _engineEvalToPositionEval(bestEval, _controller.game.turn == white);
            if (posEval != null) {
              graph.assign(stepBfen, posEval);
              graph.v[stepBfen]?.inDatabase = true;
            }
          }
        }

        await _exploreRecursive(isRoot: true);

        while (_controller.game.history.length > targetHistoryLen &&
            _controller.game.history.isNotEmpty) {
          _controller.undoMove();
        }

        if (_interactiveBacksolving) {
          if (graph is CachedGraph) {
            await (graph as CachedGraph).solveBfenAsync(stepBfen);
          } else {
            graph.solveBfen(stepBfen);
          }
        }

        if (!_isExploring || !mounted) break;
        if (_controller.game.history.isEmpty) break;

        print('[explore-history] Stepping back in move history');
        _controller.undoMove();
      }
    } finally {
      _analyzeStopwatch.stop();
      WakelockPlus.disable();

      _controller.setGame(savedGame);
      await _ensureCurrentPositionLinked();

      if (_interactiveBacksolving) {
        if (graph is CachedGraph) {
          await (graph as CachedGraph).solveBfenAsync(savedBfen);
        } else {
          graph.solveBfen(savedBfen);
        }
      }
      if (_autosolveAfterExplore) {
        await _solve();
      }

      if (mounted) {
        setState(() {
          _isExploring = false;
          _isExploringHistory = false;
          _analyzeTimeText = "";
          _analyzeChapterText = "";
          _update();
        });
      }
      print('[explore-history] Move history exploration ended/stopped.');
    }
  }

  void _explore1PlyToggle() {
    if (_isExploring1Ply || _isExploring) {
      setState(() {
        _isExploring = false;
        _isExploring1Ply = false;
      });
    } else {
      _startExploring1Ply();
    }
  }

  Future<void> _startExploring1Ply() async {
    if (!_engineAvailable || _isExploring || _isSolving || _isAnalyzingGame || _isExploringHistory) return;
    setState(() {
      _isExploring = true;
      _isExploring1Ply = true;
    });
    WakelockPlus.enable();
    print('[explore-1ply] Started wide shallow exploration of legal moves');

    final rootBfen = _controller.game.bfen;

    try {
      await _exploreLegalMoves();
    } finally {
      WakelockPlus.disable();

      while (_controller.game.bfen != rootBfen && _controller.game.history.isNotEmpty) {
        _controller.undoMove();
      }

      if (_interactiveBacksolving) {
        if (graph is CachedGraph) {
          await (graph as CachedGraph).solveBfenAsync(rootBfen);
        } else {
          graph.solveBfen(rootBfen);
        }
      }
      if (_autosolveAfterExplore) {
        await _solve();
      }

      if (mounted) {
        setState(() {
          _isExploring = false;
          _isExploring1Ply = false;
          _update();
        });
      }
      print('[explore-1ply] Exploration ended/stopped.');
    }
  }

  Future<void> _exploreLegalMoves() async {
    if (!_isExploring || !mounted) return;

    final rootBfen = _controller.game.bfen;
    final moves = _controller.game.generateMoves();
    print('[explore-1ply] Position $rootBfen: Found ${moves.length} legal moves');

    final moveSans = moves.map((m) => _controller.game.moveToSan(m)).toList();

    // Prioritize candidate moves from current engine evaluations if available
    final List<int> indices = List.generate(moves.length, (i) => i);
    final engineCandidateSans = _engineEvals
        .map((e) => _uciToSan(e.candidateMove))
        .where((s) => s != '—')
        .toList();

    indices.sort((a, b) {
      final aSan = moveSans[a];
      final bSan = moveSans[b];
      final aIdx = engineCandidateSans.indexOf(aSan);
      final bIdx = engineCandidateSans.indexOf(bSan);
      if (aIdx != -1 && bIdx != -1) return aIdx.compareTo(bIdx);
      if (aIdx != -1) return -1;
      if (bIdx != -1) return 1;
      return 0;
    });

    final tempGame = _controller.game.copy();

    for (final idx in indices) {
      if (!_isExploring || !mounted) break;

      final move = moves[idx];
      final san = moveSans[idx];

      // 1. Peek child BFEN and terminal status on copy
      tempGame.makeMove(move);
      final childBfen = tempGame.bfen;
      final isGameOver = tempGame.gameOver;
      final termEval = tempGame.terminalEvaluation;
      tempGame.undoMove();

      // Ensure graph link exists from root to child
      graph.addLink(rootBfen, childBfen);

      // If game over, assign terminal evaluation directly
      if (isGameOver) {
        if (termEval != null && graph.v[childBfen]?.assigned == null) {
          graph.assign(childBfen, termEval);
          graph.v[childBfen]?.inDatabase = true;
          if (_interactiveBacksolving) {
            if (graph is CachedGraph) {
              await (graph as CachedGraph).solveBfenAsync(childBfen);
            } else {
              graph.solveBfen(childBfen);
            }
          }
        }
        continue;
      }

      // Check if child already has an evaluation in graph
      final existingAssigned = graph.v[childBfen]?.assigned;
      final existingComputed = graph.v[childBfen]?.computed;
      if (existingAssigned != null || existingComputed != null) {
        print('[explore-1ply] Move $san ($childBfen) already evaluated: ${existingAssigned ?? existingComputed}. Skipping.');
        continue;
      }

      // 2. Play the move on the board to evaluate with engine
      print('[explore-1ply] Evaluating unassigned move: $san ($childBfen)');
      _controller.makeMoveWithNormalNotation(san);

      // Wait for engine evaluation on the resulting position
      await _waitForEngineStabilization();

      // Assign engine evaluation if available
      if (graph.v[childBfen]?.assigned == null && _engineEvals.isNotEmpty) {
        final bestEval = _engineEvals.first;
        final currentFen = _controller.game.fen;
        final currentKey = EngineCache.canonicalKey(_variant, currentFen);
        if (bestEval.fen != null &&
            EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey) {
          final posEval = _engineEvalToPositionEval(
              bestEval, _controller.game.turn == white);
          if (posEval != null) {
            graph.assign(childBfen, posEval);
            graph.v[childBfen]?.inDatabase = true;
            if (_interactiveBacksolving) {
              if (graph is CachedGraph) {
                await (graph as CachedGraph).solveBfenAsync(childBfen);
              } else {
                graph.solveBfen(childBfen);
              }
            }
          }
        }
      }

      // 3. Undo move to return to root position
      _controller.undoMove();
      if (mounted) {
        setState(_update);
      }
    }

    if (_controller.game.bfen != rootBfen) {
      _controller.undoMove();
    }
    if (mounted) {
      setState(_update);
      _requestEngineEval();
    }
  }

  bool _mateSolverStopRequested = false;

  void _stopMateSolver() {
    if (_isMateSolving) {
      _mateSolverStopRequested = true;
      setState(() {
        _isMateSolving = false;
        _mateSolverStatus = 'Stopping mate solver...';
      });
      print('[mate-solver] Stop requested.');
    }
  }

  String _formatStartPositionDescription(PlayerColor attackingColor) {
    final targetColor = attackingColor == white ? 'white' : 'black';
    if (_controller.game.history.isEmpty) {
      return 'Finding mate for $targetColor from starting position';
    }
    final g = _controller.game.copy();
    final lastMove = g.undoMove();
    if (lastMove == null) {
      return 'Finding mate for $targetColor';
    }
    final san = g.moveToSan(lastMove);
    final num = g.moveNumber;
    final isWhite = lastMove.color == white;
    final moveStr = isWhite ? '$num. $san' : '$num... $san';
    return 'Finding mate for $targetColor after $moveStr';
  }

  Future<bool> _startMateSolver({int maxDepth = 20, PlayerColor? attackingColor}) async {
    if (!_engineAvailable ||
        _isMateSolving ||
        _isExploring ||
        _isSolving ||
        _isAnalyzingGame ||
        _isExploringHistory) {
      return false;
    }

    attackingColor ??= _controller.game.turn;
    final targetColor = attackingColor == white ? 'white' : 'black';

    final startDesc = _formatStartPositionDescription(attackingColor);

    setState(() {
      _isMateSolving = true;
      _mateSolverResult = null;
      _mateSolverTitle = startDesc;
      _mateSolverStatus = 'Starting search...';
      _mateSolverNodesCount = 0;
    });
    WakelockPlus.enable();
    print('[mate-solver] Started mate-solver (maxDepth: $maxDepth, attackingColor: $attackingColor)');

    _mateSolverStopRequested = false;
    final rootBfen = _controller.game.bfen;
    final rootFen = _controller.game.fen;
    final rootHistoryLength = _controller.game.history.length;
    final pathBfens = <String>{};
    bool proven = false;
    final stopwatch = Stopwatch()..start();

    List<Move>? failureMoves;
    String? failureBfen;
    String? failureFen;
    String? failureReason;

    void onLeafFailure(String reason) {
      failureMoves = _controller.game.history.length >= rootHistoryLength
          ? _controller.game.history.sublist(rootHistoryLength).map((h) => h.move).toList()
          : <Move>[];
      failureBfen = _controller.game.bfen;
      failureFen = _controller.game.fen;
      failureReason = reason;
    }

    try {
      proven = await _proveMateRecursive(
        ply: 0,
        maxDepth: maxDepth,
        attackingColor: attackingColor,
        pathBfens: pathBfens,
        onLeafFailure: onLeafFailure,
      );
      if (proven) {
        print('[mate-solver] Successfully proven mate from $rootBfen!');
      } else {
        print('[mate-solver] Failed to prove mate within cutoff.');
      }
    } catch (e, st) {
      print('[mate-solver] Error during mate search: $e\n$st');
    } finally {
      stopwatch.stop();
      final elapsed = stopwatch.elapsed;
      WakelockPlus.disable();

      while (_controller.game.bfen != rootBfen && _controller.game.history.isNotEmpty) {
        _controller.undoMove();
      }

      final nodesExplored = _mateSolverNodesCount;
      final wasStopRequested = _mateSolverStopRequested;

      if (mounted) {
        final resultTitle = proven
            ? 'Mate Search Complete'
            : (wasStopRequested ? 'Mate Search Stopped' : 'Mate Search Failed');
        final resultMessage = proven
            ? 'Forced mate proven for $targetColor!'
            : (wasStopRequested
                ? 'Search stopped by user.'
                : 'Could not prove forced mate for $targetColor within depth cutoff.');

        setState(() {
          _isMateSolving = false;
          _mateSolverTitle = '';
          _mateSolverStatus = '';
          _mateSolverResult = MateSolverResult(
            title: resultTitle,
            message: resultMessage,
            nodes: nodesExplored,
            elapsed: elapsed,
            proven: proven,
            stopped: wasStopRequested,
            rootBfen: rootBfen,
            rootFen: rootFen,
            failureBfen: failureBfen,
            failureFen: failureFen,
            failureMoves: failureMoves,
            failureReason: failureReason,
          );
          _update();
          _requestEngineEval();
        });
      }
      print('[mate-solver] Mate solver ended/stopped in ${_formatDuration(elapsed)}.');
    }
    return proven;
  }

  Future<bool> _proveMateRecursive({
    required int ply,
    required int maxDepth,
    required PlayerColor attackingColor,
    required Set<String> pathBfens,
    required void Function(String reason) onLeafFailure,
  }) async {
    if (!_isMateSolving || !mounted) {
      onLeafFailure('Search stopped');
      return false;
    }

    _mateSolverNodesCount++;
    final bfen = _controller.game.bfen;
    final isWhiteToMove = _controller.game.turn == white;
    final isAttackerToMove = _controller.game.turn == attackingColor;

    // 1. Cycle avoidance:
    // If the position is already on the current search path, it is a repetition!
    // A repetition avoids mate, so it fails to prove mate for the attacker.
    if (pathBfens.contains(bfen)) {
      print('[mate-solver] Cycle detected at $bfen (ply $ply)');
      onLeafFailure('Repetition / cycle detected at ply $ply');
      return false;
    }

    // 2. Terminal Game Over check:
    if (_controller.game.gameOver) {
      final termEval = _controller.game.terminalEvaluation;
      if (termEval != null && (termEval >= 999.0 || termEval <= -999.0)) {
        final isWhiteWin = termEval > 0;
        final isAttackerWin = attackingColor == white ? isWhiteWin : !isWhiteWin;
        if (isAttackerWin) {
          final posEval = PositionEval.fromLegacyScore(termEval);
          if (posEval != null && graph.v[bfen]?.assigned == null) {
            graph.assign(bfen, posEval);
            graph.v[bfen]?.inDatabase = true;
            if (_interactiveBacksolving) {
              if (graph is CachedGraph) {
                await (graph as CachedGraph).solveBfenAsync(bfen);
              } else {
                graph.solveBfen(bfen);
              }
            }
          }
          return true;
        }
      }
      onLeafFailure('Game over (non-mate) at ply $ply');
      return false; // Draw, stalemate, or defender checkmate
    }

    // 3. Transposition check in graph:
    final existingEval = graph.v[bfen]?.effectiveEval;
    if (existingEval != null) {
      final isAttackerWin = attackingColor == white
          ? existingEval.result == GameResult.whiteWins
          : existingEval.result == GameResult.blackWins;
      if (isAttackerWin) {
        return true;
      }
      if (existingEval.result == GameResult.draw ||
          (attackingColor == white
              ? existingEval.result == GameResult.blackWins
              : existingEval.result == GameResult.whiteWins)) {
        onLeafFailure('Transposition already proven non-mate at ply $ply');
        return false;
      }
    }

    // 4. Wait for FSF evaluation to stabilize at this position:
    await _waitForEngineStabilization();
    if (!_isMateSolving || !mounted) {
      onLeafFailure('Search stopped');
      return false;
    }

    // 5. Check if FSF confirms mate for the attacker:
    final currentKey = EngineCache.canonicalKey(_variant, _controller.game.fen);
    final currentEvals = _engineEvals
        .where((e) =>
            e.fen != null &&
            EngineCache.canonicalKey(_variant, e.fen!) == currentKey &&
            (e.candidateMove == null ||
                EngineCache.isMoveColorConsistentWithFen(_controller.game.fen, e.candidateMove!)))
        .toList();

    if (currentEvals.isNotEmpty) {
      final bestEval = currentEvals.first;
      if (bestEval.mate != null) {
        final isAttackerMate = attackingColor == white ? bestEval.mate! > 0 : bestEval.mate! < 0;
        if (isAttackerMate) {
          final posEval = _engineEvalToPositionEval(bestEval, isWhiteToMove);
          if (posEval != null &&
              (attackingColor == white
                  ? posEval.result == GameResult.whiteWins
                  : posEval.result == GameResult.blackWins)) {
            graph.assign(bfen, posEval);
            graph.v[bfen]?.inDatabase = true;
            if (_interactiveBacksolving) {
              if (graph is CachedGraph) {
                await (graph as CachedGraph).solveBfenAsync(bfen);
              } else {
                graph.solveBfen(bfen);
              }
            }
            print('[mate-solver] FSF confirmed mate at $bfen (mate ${bestEval.mate})');
            return true;
          }
        } else {
          // Defender has forced mate
          print('[mate-solver] Defender has forced mate at $bfen (mate ${bestEval.mate})');
          onLeafFailure('Defender forced mate (M${bestEval.mate!.abs()}) at ply $ply');
          return false;
        }
      }
    }

    // 6. Check depth cutoff:
    if (ply >= maxDepth) {
      print('[mate-solver] Depth cutoff ($maxDepth) reached at $bfen without confirmed mate');
      onLeafFailure('Depth cutoff ($maxDepth plies) reached');
      return false;
    }

    // 7. Branching (Attacker = OR node / Defender = AND node):
    pathBfens.add(bfen);
    try {
      if (isAttackerToMove) {
        // ATTACKER (White): Probe ONLY the single top move. If it fails, it fails.
        if (currentEvals.isEmpty) {
          onLeafFailure('No candidate moves evaluated at ply $ply');
          return false;
        }
        final bestEval = currentEvals.first;
        final san = _uciToSan(bestEval.candidateMove);
        if (san == '—') {
          onLeafFailure('No candidate move available at ply $ply');
          return false;
        }

        // Ensure link in graph
        final moves = _controller.game.generateMoves();
        final matchedMove = moves.firstWhere(
          (m) =>
              _controller.game.moveToSan(m) == san ||
              _controller.game.normalizeMoveString(_controller.game.moveToSan(m)) ==
                  _controller.game.normalizeMoveString(san),
          orElse: () => moves.first,
        );

        final tempGame = _controller.game.copy();
        tempGame.makeMove(matchedMove);
        final childBfen = tempGame.bfen;
        graph.addLink(bfen, childBfen);

        if (graph is CachedGraph) {
          await (graph as CachedGraph).prefetchPositions([childBfen]);
        }

        if (mounted) {
          setState(() {
            _mateSolverStatus = 'Ply $ply: $san (nodes: $_mateSolverNodesCount)';
          });
        }

        final moveSuccess = _controller.makeMoveWithNormalNotation(san);
        if (!moveSuccess) {
          if (matchedMove.promotion != null) {
            _controller.makeMoveWithPromotion(
              from: matchedMove.fromAlgebraic,
              to: matchedMove.toAlgebraic,
              pieceToPromoteTo: matchedMove.promotion!.name.toUpperCase(),
            );
          } else {
            _controller.makeMove(
              from: matchedMove.fromAlgebraic,
              to: matchedMove.toAlgebraic,
            );
          }
        }

        final success = await _proveMateRecursive(
          ply: ply + 1,
          maxDepth: maxDepth,
          attackingColor: attackingColor,
          pathBfens: pathBfens,
          onLeafFailure: onLeafFailure,
        );
        _controller.undoMove();

        if (success) {
          if (_interactiveBacksolving) {
            if (graph is CachedGraph) {
              await (graph as CachedGraph).solveBfenAsync(bfen);
            } else {
              graph.solveBfen(bfen);
            }
          }
          return true;
        }
        return false;
      } else {
        // DEFENDER (Black): AND-node. Must refute ALL legal moves.
        final moves = _controller.game.generateMoves();
        if (moves.isEmpty) {
          onLeafFailure('No legal moves at ply $ply');
          return false;
        }

        final moveSans = moves.map((m) => _controller.game.moveToSan(m)).toList();

        // Order defender moves best-first (defensive order: FSF best defenses first)
        final List<int> indices = List.generate(moves.length, (i) => i);
        final engineCandidateSans = currentEvals
            .map((e) => _uciToSan(e.candidateMove))
            .where((s) => s != '—')
            .toList();

        indices.sort((a, b) {
          final aSan = moveSans[a];
          final bSan = moveSans[b];
          final aIdx = engineCandidateSans.indexOf(aSan);
          final bIdx = engineCandidateSans.indexOf(bSan);
          if (aIdx != -1 && bIdx != -1) return aIdx.compareTo(bIdx);
          if (aIdx != -1) return -1;
          if (bIdx != -1) return 1;
          return 0;
        });

        // Ensure links in graph
        final tempGame = _controller.game.copy();
        final childBfens = <String>[];
        for (final idx in indices) {
          tempGame.makeMove(moves[idx]);
          final childBfen = tempGame.bfen;
          childBfens.add(childBfen);
          graph.addLink(bfen, childBfen);
          tempGame.undo();
        }
        if (graph is CachedGraph) {
          await (graph as CachedGraph).prefetchPositions(childBfens);
        }

        // Test each defense. If ANY defense avoids mate, fail-fast!
        for (int i = 0; i < indices.length; i++) {
          if (!_isMateSolving || !mounted) {
            onLeafFailure('Search stopped');
            return false;
          }

          final idx = indices[i];
          final san = moveSans[idx];
          final move = moves[idx];

          if (mounted) {
            setState(() {
              _mateSolverStatus = 'Ply $ply: defend $san (${i + 1}/${indices.length}, nodes: $_mateSolverNodesCount)';
            });
          }

          final moveSuccess = _controller.makeMoveWithNormalNotation(san);
          if (!moveSuccess) {
            if (move.promotion != null) {
              _controller.makeMoveWithPromotion(
                from: move.fromAlgebraic,
                to: move.toAlgebraic,
                pieceToPromoteTo: move.promotion!.name.toUpperCase(),
              );
            } else {
              _controller.makeMove(
                from: move.fromAlgebraic,
                to: move.toAlgebraic,
              );
            }
          }

          final childSuccess = await _proveMateRecursive(
            ply: ply + 1,
            maxDepth: maxDepth,
            attackingColor: attackingColor,
            pathBfens: pathBfens,
            onLeafFailure: onLeafFailure,
          );
          _controller.undoMove();

          if (!childSuccess) {
            print('[mate-solver] Defender move $san refutes line (did not lead to mate)');
            return false;
          }
        }

        // All defender moves led to mate!
        if (_interactiveBacksolving) {
          if (graph is CachedGraph) {
            await (graph as CachedGraph).solveBfenAsync(bfen);
          } else {
            graph.solveBfen(bfen);
          }
        }
        return true;
      }
    } finally {
      pathBfens.remove(bfen);
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
        final bool hasReachedTarget = bestEval.mate != null ||
            (bestEval.depth != null &&
                bestEval.depth! >= 16);
        if (isCurrentPos &&
            (hasReachedTarget || !widget.engineService.isSearching)) {
          break;
        }
      }
      if (stabilizationStopwatch.elapsedMilliseconds > 30000) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }

    if (!_isExploring || !mounted) return;

    final knownMoveSans = _getKnownMoveSans();
    final isWhite = _controller.game.turn == white;
    final hasKnownWinningMate = _knownMoves.any((m) =>
        m.score != null && (isWhite ? m.score! >= 999.0 : m.score! <= -999.0));

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

    final attemptedMoves = <String>{};

    while (_isExploring && mounted) {
      final currentEvaluatedSans = _getEvaluatedMoveSans();
      final currentIsWhite = _controller.game.turn == white;
      final currentHasWinningMate = _knownMoves.any((m) =>
          m.score != null && (currentIsWhite ? m.score! >= 999.0 : m.score! <= -999.0));

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
            currentEvaluatedSans.contains(_controller.game.normalizeMoveString(currentWinningMateSan)) ||
            attemptedMoves.contains(currentWinningMateSan) ||
            attemptedMoves.contains(_controller.game.normalizeMoveString(currentWinningMateSan))) {
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
              !currentEvaluatedSans.contains(_controller.game.normalizeMoveString(san)) &&
              !attemptedMoves.contains(san) &&
              !attemptedMoves.contains(_controller.game.normalizeMoveString(san))) {
            nextMoveToExplore = san;
            break;
          }
        }
        if (nextMoveToExplore == null) {
          for (final m in _knownMoves) {
            if (m.eval == null &&
                !attemptedMoves.contains(m.move) &&
                !attemptedMoves.contains(_controller.game.normalizeMoveString(m.move))) {
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

      attemptedMoves.add(nextMoveToExplore);
      attemptedMoves.add(_controller.game.normalizeMoveString(nextMoveToExplore));

      print(
          '[explore] Choosing to explore unexplored move: $nextMoveToExplore');
      _controller.makeMoveWithNormalNotation(nextMoveToExplore);

      final bfen = _controller.game.bfen;
      if (graph is CachedGraph) {
        final g = _controller.game.copy();
        final children = <String>[];
        for (final m in g.generateMoves()) {
          g.makeMove(m);
          children.add(g.bfen);
          g.undo();
        }
        await (graph as CachedGraph).prefetchPositions([bfen, ...children]);
        if (mounted) {
          setState(_update);
        }
      }
      if (graph.v[bfen]?.assigned == null && graph.v[bfen]?.computed == null) {
        await _waitForEngineStabilization();
        if (graph.v[bfen]?.assigned == null && _engineEvals.isNotEmpty) {
          final bestEval = _engineEvals.first;
          final currentFen = _controller.game.fen;
          final currentKey = EngineCache.canonicalKey(_variant, currentFen);
          if (bestEval.fen != null &&
              EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey) {
            final posEval = _engineEvalToPositionEval(bestEval, _controller.game.turn == white);
            if (posEval != null) {
              graph.assign(bfen, posEval);
              graph.v[bfen]?.inDatabase = true;
              if (_interactiveBacksolving) {
                if (graph is CachedGraph) {
                  await (graph as CachedGraph).solveBfenAsync(bfen);
                } else {
                  graph.solveBfen(bfen);
                }
              }
            }
          }
        }
      }

      if (!_isExploring || !mounted) break;
      print(
          '[explore] Evaluation for $nextMoveToExplore completed.');

      // Recursively explore the resulting position
      await _exploreRecursive(isRoot: false);

      if (!_isExploring || !mounted) break;

      print('[explore] Returning to parent position.');
      _controller.undoMove();
      if (mounted) {
        setState(_update);
      }
      await _waitForEngineStabilization();
    }
  }

  Future<void> _waitForEngineStabilization() async {
    if ((!_isExploring && !_isMateSolving) || !mounted) return;
    final currentFen = _controller.game.fen;
    final currentKey = EngineCache.canonicalKey(_variant, currentFen);
    if (!_engineEvalPending && _engineEvals.isNotEmpty) {
      final bestEval = _engineEvals.first;
      final bool hasReachedTarget = bestEval.mate != null ||
          bestEval.isPseudoMate ||
          (bestEval.depth != null &&
              bestEval.depth! >= 16);
      if (bestEval.fen != null &&
          EngineCache.canonicalKey(_variant, bestEval.fen!) == currentKey &&
          (bestEval.candidateMove == null ||
              EngineCache.isMoveColorConsistentWithFen(currentFen, bestEval.candidateMove!)) &&
          (hasReachedTarget || !widget.engineService.isSearching)) {
        return;
      }
    }
    await Future.delayed(const Duration(milliseconds: 150));
    final stopwatch = Stopwatch()..start();
    while ((_isExploring || _isMateSolving) &&
        mounted &&
        (_engineEvalPending || _engineEvals.isEmpty)) {
      if (stopwatch.elapsedMilliseconds > 3000 && !widget.engineService.isSearching) {
        break;
      }
      await Future.delayed(const Duration(milliseconds: 100));
    }
    while ((_isExploring || _isMateSolving) && mounted) {
      if (_engineEvals.isNotEmpty) {
        final bestEval = _engineEvals.first;
        final bool isCurrentPos = bestEval.fen != null &&
            EngineCache.canonicalKey(_variant, bestEval.fen!) ==
                EngineCache.canonicalKey(_variant, _controller.game.fen) &&
            (bestEval.candidateMove == null ||
                EngineCache.isMoveColorConsistentWithFen(_controller.game.fen, bestEval.candidateMove!));
        final bool hasReachedTarget = bestEval.mate != null ||
            bestEval.isPseudoMate ||
            (bestEval.depth != null &&
                bestEval.depth! >= 16);
        if (isCurrentPos &&
            (hasReachedTarget || !widget.engineService.isSearching)) {
          break;
        }
      }
      if (stopwatch.elapsedMilliseconds > 30000) {
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
        final vName = v.name.toLowerCase();
        final vLabel = v.label.toLowerCase();
        if (vName == pgnVar || vLabel == pgnVar || pgnVar.contains(vName) || pgnVar.contains(vLabel)) {
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
            final vName = v.name.toLowerCase();
            final vLabel = v.label.toLowerCase();
            if (vName == pgnVar || vLabel == pgnVar || pgnVar.contains(vName) || pgnVar.contains(vLabel)) {
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
      WakelockPlus.disable();
      if (mounted) {
        setState(() {
          _isExploring = false;
          _isAnalyzingGame = false;
          _analyzeTimeText = "";
          _analyzeChapterText = "";
        });
      }
      print('[analyze] Game/study analysis ended/stopped.');
      if (_interactiveBacksolving) {
        final currentBfen = _controller.game.bfen;
        if (graph is CachedGraph) {
          await (graph as CachedGraph).solveBfenAsync(currentBfen);
        } else {
          graph.solveBfen(currentBfen);
        }
      }
      if (_autosolveAfterExplore) {
        await _solve();
      }
      if (mounted) {
        setState(_update);
      }
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
        final posEval = _engineEvalToPositionEval(eval, isWhiteToMove);
        if (posEval != null) {
          graph.assign(bfen, posEval);
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

  _evaluationWidget({double width = 280.0}) {
    return _textField("Evaluation", _evalController, _updateEval, width: width);
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

  Widget _engineWidget({double width = 280.0}) {
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
          if (e.isPseudoMate) {
            evalStr = e.centipawns! > 0 ? '+Mate' : '-Mate';
          } else {
            final pawns = e.centipawns! / 100.0;
            evalStr = pawns > 0
                ? '+${pawns.toStringAsFixed(2)}'
                : pawns.toStringAsFixed(2);
          }
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
                Text(depth == 100 ? 'Tablebase' : 'Depth $depth',
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
          width: width,
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

  @visibleForTesting
  String formatMoveHistory() {
    if (_controller.game.history.isEmpty) return '';
    final game = _controller.game.copy();
    final reversedMoves = <Move>[];
    while (game.history.isNotEmpty) {
      final m = game.undoMove();
      if (m == null) break;
      reversedMoves.add(m);
    }

    final parts = <String>[];
    bool isFirst = true;
    while (reversedMoves.isNotEmpty) {
      final move = reversedMoves.removeLast();
      final san = game.moveToSan(move);
      if (move.color == white) {
        parts.add('${game.moveNumber}. $san');
      } else if (isFirst) {
        parts.add('${game.moveNumber}... $san');
      } else {
        parts.add(san);
      }
      isFirst = false;
      game.makeMove(move);
    }
    return parts.join(' ');
  }

  Widget _moveHistoryWidget({double width = 280.0}) {
    final historyText = formatMoveHistory();
    return SizedBox(
      width: width,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: 'Move History',
          border: const OutlineInputBorder(),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          suffixIcon: historyText.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.copy, size: 18),
                  tooltip: 'Copy move history',
                  onPressed: _copyMoveHistoryToClipboard,
                )
              : null,
        ),
        child: Text(
          historyText.isEmpty ? '—' : historyText,
          key: const ValueKey('move-history-text'),
          style: TextStyle(
            fontSize: historyText.isEmpty ? 20 : 16,
            height: historyText.isEmpty ? null : 1.4,
          ),
        ),
      ),
    );
  }

  _updateEval(String newEval) {
    String bfen = _controller.game.bfen;
    graph.assign(bfen, _parsePositionEval(newEval));
    graph.v[bfen]?.inDatabase = true;
    if (_interactiveBacksolving) {
      if (graph is CachedGraph) {
        (graph as CachedGraph).solveBfenAsync(bfen).then((_) {
          if (mounted) setState(_update);
        });
      } else {
        graph.solveBfen(bfen);
        if (mounted) {
          setState(_update);
        }
      }
    } else {
      if (mounted) {
        setState(_update);
      }
    }
  }

  _textField(label, TextEditingController controller, onSubmitted, {double width = 280.0}) {
    return SizedBox(
      width: width,
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
  PositionEval? _engineEvalToPositionEval(EngineEvaluation eval, bool whiteToMove, {DatasetVariant? variant}) {
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
        return PositionEval.fromLegacyScore(termScore);
      }
      final absM = m.abs();
      final sideToMoveIsWinning = whiteToMove ? (m > 0) : (m < 0);
      final int pliesToMate;
      if (eval.dtw != null) {
        pliesToMate = eval.dtw!;
      } else if (variant == DatasetVariant.antichess) {
        pliesToMate = sideToMoveIsWinning ? (2 * absM) : (2 * absM - 1);
      } else {
        pliesToMate = sideToMoveIsWinning ? (2 * absM - 1) : (2 * absM);
      }
      final result = m > 0 ? GameResult.whiteWins : GameResult.blackWins;
      return PositionEval(result: result, dtw: pliesToMate);
    } else if (eval.centipawns != null) {
      if (eval.isPseudoMate) {
        final isWhiteWin = eval.centipawns! > 0;
        final result = isWhiteWin ? GameResult.whiteWins : GameResult.blackWins;
        return PositionEval(result: result, dtw: eval.dtw);
      }
      return PositionEval(cp: eval.centipawns);
    }
    return null;
  }

  double? _engineEvalToGraphScore(EngineEvaluation eval, bool whiteToMove, {DatasetVariant? variant}) =>
      _engineEvalToPositionEval(eval, whiteToMove, variant: variant)?.toLegacyScore();

  bool _isWinningMateInOne(EngineEvaluation eval, bool isWhiteToMove) {
    if (eval.candidateMove == null) return false;
    if (eval.isPseudoMate || eval.mate == null) return false;
    final posEval = _engineEvalToPositionEval(eval, isWhiteToMove);
    if (posEval == null) return false;
    if (_variant == DatasetVariant.antichess) {
      return isWhiteToMove
          ? (posEval.result == GameResult.whiteWins && posEval.dtw != null && posEval.dtw! <= 2)
          : (posEval.result == GameResult.blackWins && posEval.dtw != null && posEval.dtw! <= 2);
    }
    return isWhiteToMove
        ? (posEval.result == GameResult.whiteWins && posEval.dtw != null && posEval.dtw! <= 1)
        : (posEval.result == GameResult.blackWins && posEval.dtw != null && posEval.dtw! <= 1);
  }

  String _formatScore(dynamic scoreOrEval, {bool wrapInParentheses = false, bool isMoveScore = false}) {
    if (scoreOrEval is PositionEval) {
      final formatted = scoreOrEval.format(isMove: isMoveScore);
      return wrapInParentheses ? '($formatted)' : formatted;
    }
    if (scoreOrEval is! num) return '';
    final double score = scoreOrEval.toDouble();
    const double mateThreshold = Graph.mateThreshold;
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
    } else if (score.abs() >= 150.0) {
      formatted = score > 0 ? '+Mate' : '-Mate';
    } else {
      formatted = score > 0 ? '+${score.toStringAsFixed(2)}' : score.toStringAsFixed(2);
    }
    return wrapInParentheses ? '($formatted)' : formatted;
  }

  @visibleForTesting
  double? engineEvalToGraphScore(EngineEvaluation eval, bool whiteToMove, {DatasetVariant? variant}) =>
      _engineEvalToGraphScore(eval, whiteToMove, variant: variant);

  @visibleForTesting
  PositionEval? engineEvalToPositionEval(EngineEvaluation eval, bool whiteToMove, {DatasetVariant? variant}) =>
      _engineEvalToPositionEval(eval, whiteToMove, variant: variant);

  @visibleForTesting
  String formatScore(dynamic score, {bool wrapInParentheses = false, bool isMoveScore = false}) =>
      _formatScore(score, wrapInParentheses: wrapInParentheses, isMoveScore: isMoveScore);

  @visibleForTesting
  Future<void> waitForEngineStabilization() => _waitForEngineStabilization();

  PositionEval? _parsePositionEval(String text) {
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
      return PositionEval(
        result: sign > 0 ? GameResult.whiteWins : GameResult.blackWins,
        dtw: plies,
      );
    }

    final dtzRegex = RegExp(r'^([+-]?)DTZ\s*(\d+)$', caseSensitive: false);
    final dtzMatch = dtzRegex.firstMatch(text);
    if (dtzMatch != null) {
      final sign = dtzMatch.group(1) == '-' ? -1 : 1;
      return PositionEval(
        result: sign > 0 ? GameResult.whiteWins : GameResult.blackWins,
      );
    }

    final pseudoMateRegex =
        RegExp(r'^([+-]?)Mate(?:\s*\(?DTZ\s*(\d+)\)?)?$', caseSensitive: false);
    final pseudoMatch = pseudoMateRegex.firstMatch(text);
    if (pseudoMatch != null) {
      final sign = pseudoMatch.group(1) == '-' ? -1 : 1;
      return PositionEval(
        result: sign > 0 ? GameResult.whiteWins : GameResult.blackWins,
      );
    }

    final lower = text.trim().toLowerCase();
    if (lower == 'draw' || lower == '1/2-1/2' || lower == '½-½') {
      return const PositionEval(result: GameResult.draw, cp: 0);
    }

    if (text == '0' || text == '0.0' || text == '0.00') {
      return const PositionEval(cp: 0);
    }

    final parsed = double.tryParse(text);
    if (parsed != null) {
      return PositionEval.fromLegacyScore(parsed);
    }

    return null;
  }

  double? _parseScore(String text) => _parsePositionEval(text)?.toLegacyScore();

  @visibleForTesting
  double? parseScore(String text) => _parseScore(text);

  @visibleForTesting
  PositionEval? parsePositionEval(String text) => _parsePositionEval(text);

  @visibleForTesting
  Set<String> getEvaluatedMoveSans() => _getEvaluatedMoveSans();

  @visibleForTesting
  Set<String> getKnownMoveSans() => _getKnownMoveSans();

  @visibleForTesting
  List<MoveInfo> get knownMoves => _knownMoves;

  @visibleForTesting
  int Function(MoveInfo, MoveInfo) compareMoves(PlayerColor turn) => _compare(turn);

  @visibleForTesting
  bool get isExploring => _isExploring;

  @visibleForTesting
  Future<void> startExploring() => _startExploring();

  @visibleForTesting
  bool get isAnalyzingGame => _isAnalyzingGame;

  @visibleForTesting
  Future<void> analyzeGame(String pgnText) => _analyzeGame(pgnText);

  @visibleForTesting
  TextEditingController get evalController => _evalController;

  @visibleForTesting
  String get evalText => _eval;

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
        return Chess();
    }
  }
}

class MoveInfo {
  String move;
  PositionEval? eval;

  MoveInfo(this.move, dynamic evalOrScore) {
    if (evalOrScore is PositionEval?) {
      eval = evalOrScore;
    } else if (evalOrScore is num?) {
      eval = PositionEval.fromLegacyScore(evalOrScore?.toDouble());
    }
  }

  double? get score => eval?.toLegacyScore();
}

class MateSolverResult {
  final String title;
  final String message;
  final int nodes;
  final Duration elapsed;
  final bool proven;
  final bool stopped;
  final String? rootBfen;
  final String? rootFen;
  final String? failureBfen;
  final String? failureFen;
  final List<Move>? failureMoves;
  final String? failureReason;

  const MateSolverResult({
    required this.title,
    required this.message,
    required this.nodes,
    this.elapsed = Duration.zero,
    this.proven = false,
    this.stopped = false,
    this.rootBfen,
    this.rootFen,
    this.failureBfen,
    this.failureFen,
    this.failureMoves,
    this.failureReason,
  });
}
