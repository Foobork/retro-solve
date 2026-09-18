// ignore_for_file: avoid_print

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
import 'package:retro_solve/dataset_variant.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/persistence/database_service.dart';
import 'package:retro_solve/persistence/db_init.dart';

import '../chess/chess.dart';

double? parseEvalString(String? s) {
  if (s == null) return null;
  if (s == "-") return null;
  return double.parse(s);
}

Future<void> importGraph(String filename) async {
  try {
    final normalized = filename.replaceAll('\\', '/');
    final baseName = normalized.split('/').last;
    final dbName = baseName.replaceAll('.txt', '.db');
    final dbPath = resolvePlatformDbPath(dbName);

    String variant = 'standard';
    final lower = filename.toLowerCase();
    if (lower.contains('threecheck')) {
      variant = 'threecheck';
    } else if (lower.contains('koth')) {
      variant = 'koth';
    } else if (lower.contains('crazyhouse')) {
      variant = 'crazyhouse';
    } else if (lower.contains('antichess')) {
      variant = 'antichess';
    } else if (lower.contains('atomic')) {
      variant = 'atomic';
    } else if (lower.contains('horde')) {
      variant = 'horde';
    } else if (lower.contains('racingkings')) {
      variant = 'racingkings';
    }

    print("Opening database for variant $variant at $dbPath");
    await DatabaseService.instance.init(dbPath);

    final posCount = await DatabaseService.instance.getPositionCount();
    if (posCount > 0) {
      if (graph is CachedGraph) {
        print("Database opened for $variant ($posCount positions). Fast on-demand startup.");
        final game = createGameForVariant(variant);
        final startBfen = game.bfen;
        final moves = game.generateMoves();
        final childBfens = <String>[];
        for (var move in moves) {
          game.makeMove(move);
          childBfens.add(game.bfen);
          game.undo();
        }
        await (graph as CachedGraph).prefetchPositions([startBfen, ...childBfens]);
        final children = await DatabaseService.instance.getChildrenBfens(startBfen);
        graph.v[startBfen]?.links.addAll(children);
        return;
      }

      final nodes = await DatabaseService.instance.loadNodes();
      print("Loading ${nodes.length} nodes from database $dbPath");
      for (var node in nodes) {
        PositionEval? assignedEval;
        PositionEval? computedEval;
        if (node.containsKey('assigned_result') || node.containsKey('assigned_cp')) {
          assignedEval = PositionEval(
            result: GameResult.fromInt(node['assigned_result'] as int?),
            dtw: node['assigned_dtw'] as int?,
            dtz: node['assigned_dtz'] as int?,
            cp: node['assigned_cp'] as int?,
          );
          computedEval = PositionEval(
            result: GameResult.fromInt(node['computed_result'] as int?),
            dtw: node['computed_dtw'] as int?,
            dtz: node['computed_dtz'] as int?,
            cp: node['computed_cp'] as int?,
          );
          if (assignedEval.result == null &&
              assignedEval.dtw == null &&
              assignedEval.dtz == null &&
              assignedEval.cp == null) {
            assignedEval = null;
          }
          if (computedEval.result == null &&
              computedEval.dtw == null &&
              computedEval.dtz == null &&
              computedEval.cp == null) {
            computedEval = null;
          }
        } else {
          assignedEval =
              PositionEval.fromLegacyScore(node['assigned'] as double?);
          computedEval =
              PositionEval.fromLegacyScore(node['computed'] as double?);
        }
        graph.addFullVertex(
          node['bfen'] as String,
          assignedEval,
          computedEval,
        );
      }
      print("Nodes loaded: ${graph.v.length}. Loading edges...");
      final oldOnEdgeAdded = graph.onEdgeAdded;
      graph.onEdgeAdded = null;
      int edgeCount = 0;
      await DatabaseService.instance.loadEdges(
        onEdge: (source, target) {
          graph.addLink(source, target);
          edgeCount++;
        },
      );
      graph.onEdgeAdded = oldOnEdgeAdded;

      if (edgeCount == 0 && nodes.isNotEmpty) {
        print("Legacy DB detected (0 edges). Regenerating edges...");
        final bfens = graph.v.keys.toList();
        int count = 0;
        for (var bfen in bfens) {
          if (count % 250 == 0) {
            print("Edges generated: $count / ${bfens.length} (${DatabaseService.instance.getEdgeQueueLength()} pending)");
            await Future.delayed(const Duration(milliseconds: 100));
          }
          _addEdgesForBfen(bfen, variant: variant);
          count++;
        }
        while (DatabaseService.instance.getEdgeQueueLength() > 0) {
          await Future.delayed(const Duration(milliseconds: 200));
        }
      }

      final shouldSolve = await SolveOnStartupStore.load();
      final hasComputedEvaluations = nodes.any((n) =>
          (n['computed_result'] != null || n['computed_cp'] != null || n['computed'] != null));

      if (shouldSolve || !hasComputedEvaluations) {
        print("importGraph done (from DB). Final vertices count: ${graph.v.length}. Solving graph...");
        graph.solve();
      } else {
        print("importGraph done (from DB). Final vertices count: ${graph.v.length}. Fast startup (using persisted evaluations, bypassing full solve).");
      }
      return;
    }

    // Fallback: Initial load from bundled asset
    String? content;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      final allAssets = manifest.listAssets().toSet();
      final assetCandidates = [
        normalized,
        'data/$baseName',
        baseName,
        'assets/data/$baseName',
        'assets/$baseName',
      ];
      for (final candidate in assetCandidates) {
        if (allAssets.contains(candidate)) {
          content = await rootBundle.loadString(candidate);
          if (content.isNotEmpty) break;
        }
      }
    } catch (_) {}

    if (content == null || content.isEmpty) {
      print("Starting with clean repertoire database for $variant ($dbPath).");
      return;
    }

    print("Importing initial dataset from asset $filename into database $dbPath");
    _importFromLines(content.split('\n'), variant: variant);

    for (var entry in graph.v.entries) {
      if (entry.value.inDatabase || entry.value.computed != null) {
        await DatabaseService.instance.upsertNode(
          entry.key,
          entry.value.assigned,
          entry.value.computed,
        );
      }
      for (var link in entry.value.links) {
        await DatabaseService.instance.upsertEdge(entry.key, link);
      }
    }
    print("importGraph done (migrated from asset). Solving graph...");
    graph.solve();
  } catch (e) {
    print("Error in importGraph: $e");
  }
}

void _importFromLines(List<String> lines, {required String variant}) {
  var regex = RegExp(r"^(.* .* .* .*) (.*) (.*)$");
  int lineNumber = 1;
  for (var line in lines) {
    line = line.trim();
    if (line.isEmpty) continue;
    if (lineNumber % 1000 == 0) print(lineNumber);
    var match = regex.firstMatch(line);
    if (match == null) continue;

    var bfen = match.group(1) as String;
    var assigned = parseEvalString(match.group(2));
    var computed = parseEvalString(match.group(3));
    graph.addFullVertex(bfen, assigned, computed);
    _addEdgesForBfen(bfen, variant: variant);
    lineNumber++;
  }
}

Chess createGameForVariant(String variant) {
  final lower = variant.toLowerCase();
  if (lower.contains('threecheck')) {
    return ThreeCheckChess();
  } else if (lower.contains('koth')) {
    return KothChess();
  } else if (lower.contains('crazyhouse')) {
    return CrazyhouseChess();
  } else if (lower.contains('antichess')) {
    return AntichessChess();
  } else if (lower.contains('atomic')) {
    return AtomicChess();
  } else if (lower.contains('horde')) {
    return HordeChess();
  } else if (lower.contains('racingkings')) {
    return RacingKingsChess();
  } else {
    return Chess();
  }
}

void _addEdgesForBfen(String bfen, {String variant = 'standard'}) {
  final game = createGameForVariant(variant);

  final parts = bfen.split(' ');
  final fullFen = parts.length >= 4 ? "$bfen 0 1" : bfen;

  try {
    game.load(fullFen);
    String a = game.bfen;
    if (game.gameOver) {
      final score = game.terminalEvaluation;
      if (score != null) {
        graph.assign(a, score);
      }
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
  } catch (e) {
    print("Error loading FEN $bfen: $e");
  }
}
