// ignore_for_file: avoid_print
import 'dart:io';

import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/persistence/database_service.dart';

import '../chess/chess.dart';

double? parseEvalString(String? s) {
  if (s == null) return null;
  if (s == "-") return null;
  return double.parse(s);
}

Future<void> importGraph(String filename) async {
  try {
    final absolutePath = File(filename).absolute.path;
    final dbPath = absolutePath.replaceAll('.txt', '.db');
    print("dbPath $dbPath");
    if (File(dbPath).existsSync()) {
      print("Loading from database $dbPath");
      await DatabaseService.instance.init(dbPath);
      final nodes = await DatabaseService.instance.loadNodes();
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
        print("Legacy DB detected (0 edges). Regenerating and migrating edges (this will take a while)...");
        final bfens = graph.v.keys.toList();
        int count = 0;
        for (var bfen in bfens) {
          if (count % 250 == 0) {
            print("Edges generated: $count / ${bfens.length} (${DatabaseService.instance.getEdgeQueueLength()} pending)");
            await Future.delayed(const Duration(milliseconds: 100));
          }
          _addEdgesForBfen(bfen);
          count++;
        }
        // Give final flushes a chance to drain
        while (DatabaseService.instance.getEdgeQueueLength() > 0) {
          print("Draining final edges... (${DatabaseService.instance.getEdgeQueueLength()} pending)");
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
      
      print("importGraph done (from DB)");
      return;
    }

    // Fallback to TXT
    _importFromTxt(filename);

    // Initial migration to DB
    print("Migrating to database $dbPath");
    await DatabaseService.instance.init(dbPath);
    // Use a transaction or batch if possible, but for initial migration 
    // we'll just upsert them. We only migrate nodes that were in the original txt
    // (which have inDatabase=true or computed evaluation).
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
    print("importGraph done (migrated from TXT)");
  } catch (e) {
    print("Error in importGraph: $e");
  }
}

void _importFromTxt(String filename) {
  var regex = RegExp(r"^(.* .* .* .*) (.*) (.*)$");
  var lines = File(filename).readAsLinesSync();
  int lineNumber = 1;
  for (var line in lines) {
    if (lineNumber % 1000 == 0) print(lineNumber);
    var match = regex.firstMatch(line);
    if (match == null) continue; // Skip malformed lines

    var bfen = match.group(1) as String;
    var assigned = parseEvalString(match.group(2));
    var computed = parseEvalString(match.group(3));
    graph.addFullVertex(bfen, assigned, computed);
    _addEdgesForBfen(bfen);
    lineNumber++;
  }
}



void _addEdgesForBfen(String bfen) {
  var game = Chess();
  // Ensure we have a valid FEN for chess library (append halfmove/fullmove if missing)
  final parts = bfen.split(' ');
  final fullFen = parts.length >= 4 ? "$bfen 0 1" : bfen;
  
  try {
    game.load(fullFen);
    List<Move> moves = game.generateMoves();
    String a = game.bfen;
    for (var move in moves) {
      game.makeMove(move);
      String b = game.bfen;
      game.undo();
      graph.addLink(a, b);
    }
  } catch (e) {
    print("Error loading FEN $bfen: $e");
  }
}
