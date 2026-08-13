// ignore_for_file: avoid_print

import 'package:flutter/services.dart' show rootBundle, AssetManifest;
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
    final nodes = await DatabaseService.instance.loadNodes();

    if (nodes.isNotEmpty) {
      print("Loading ${nodes.length} nodes from database $dbPath");
      for (var node in nodes) {
        graph.addFullVertex(
          node['bfen'] as String,
          node['assigned'] as double?,
          node['computed'] as double?,
        );
      }
      print("Nodes loaded: ${graph.v.length}. Loading edges...");
      final edges = await DatabaseService.instance.loadEdges();

      if (edges.isEmpty && nodes.isNotEmpty) {
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
      } else {
        final oldOnEdgeAdded = graph.onEdgeAdded;
        graph.onEdgeAdded = null;
        for (var edge in edges) {
          graph.addLink(edge['source'] as String, edge['target'] as String);
        }
        graph.onEdgeAdded = oldOnEdgeAdded;
      }

      print("importGraph done (from DB). Final vertices count: ${graph.v.length}");
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
    print("importGraph done (migrated from asset)");
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

void _addEdgesForBfen(String bfen, {String variant = 'standard'}) {
  Chess game;
  if (variant == 'threecheck') {
    game = ThreeCheckChess();
  } else if (variant == 'koth') {
    game = KothChess();
  } else if (variant == 'crazyhouse') {
    game = CrazyhouseChess();
  } else if (variant == 'antichess') {
    game = AntichessChess();
  } else if (variant == 'atomic') {
    game = AtomicChess();
  } else if (variant == 'horde') {
    game = HordeChess();
  } else if (variant == 'racingkings') {
    game = RacingKingsChess();
  } else {
    game = Chess();
  }

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
