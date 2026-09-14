// ignore_for_file: avoid_print

import 'position_eval.dart';
import 'tarjan.dart';
export 'position_eval.dart';

typedef NodeUpdateCallback = void Function(
    String bfen, PositionEval? assigned, PositionEval? computed);
typedef EdgeUpdateCallback = void Function(String fromBfen, String toBfen);

class Graph {
  /// Scores with absolute value >= mateThreshold represent forced mate evaluations.
  /// A threshold of 200.0 supports mate distances up to 400 moves (800 plies: 1000.0 - 800.0 = 200.0).
  static const double mateThreshold = 200.0;

  final Map<String, Vertex> v = {};
  NodeUpdateCallback? onNodeUpdated;
  EdgeUpdateCallback? onEdgeAdded;

  Vertex addVertex(String bfen) {
    return v.putIfAbsent(bfen, () => Vertex(bfen));
  }

  Vertex addFullVertex(String bfen, dynamic assigned, dynamic computed) {
    Vertex pos = v.putIfAbsent(bfen, () => Vertex(bfen));
    pos.assigned = assigned is PositionEval?
        ? assigned
        : PositionEval.fromLegacyScore(assigned as double?);
    pos.computed = computed is PositionEval?
        ? computed
        : PositionEval.fromLegacyScore(computed as double?);
    pos.inDatabase = true;
    return pos;
  }

  void addLink(String a, String b) {
    final bool isNew = addVertex(a).links.add(b);
    addVertex(b).backLinks.add(a);
    if (isNew) {
      onEdgeAdded?.call(a, b);
    }
  }

  void assign(String bfen, dynamic eval) {
    final pos = addVertex(bfen);
    if (eval is PositionEval?) {
      pos.assigned = eval;
    } else if (eval is double?) {
      pos.assigned = PositionEval.fromLegacyScore(eval);
    }
    pos.computed = null;
    pos.inDatabase = true;
    onNodeUpdated?.call(bfen, pos.assigned, pos.computed);
  }

  void solve() {
    print("Preparing full graph solve (SCC)...");
    for (var vertex in v.values) {
      vertex._originalComputed = vertex.computed;
      vertex.computed = null;
    }

    Map<String, Iterable<String>> outEdges = {};
    for (var bfen in v.keys) {
      outEdges[bfen] = v[bfen]!.links;
    }

    final tarjan = Tarjan();
    final sccs = tarjan.execute(outEdges);
    print("Found ${sccs.length} SCCs");

    int sccCount = 0;
    for (var scc in sccs) {
      sccCount++;
      if (sccCount % 10000 == 0) {
        print("Solved $sccCount / ${sccs.length} SCCs");
      }
      _solveSCC(scc);
    }
    print("solved");
  }

  void solveBfen(String bfen) {
    // Local retrograde solve for a single node's reachable subgraph
    if (!v.containsKey(bfen)) return;

    // 1. Upstream BFS to find all affected ancestor nodes
    final upstreamNodes = <String>{bfen};
    final queue = [bfen];
    while (queue.isNotEmpty) {
      final curr = queue.removeLast();
      for (var parent in v[curr]!.backLinks) {
        if (upstreamNodes.add(parent)) {
          queue.add(parent);
        }
      }
    }

    // 2. Build local subgraph of outEdges & reset computed values
    Map<String, Iterable<String>> subGraphOutEdges = {};
    for (String node in upstreamNodes) {
      subGraphOutEdges[node] =
          v[node]!.links.where((l) => upstreamNodes.contains(l));

      v[node]!._originalComputed = v[node]!.computed;
      if (v[node]!.assigned == null) {
        v[node]!.computed = null;
      }
    }

    // 3. Extract local SCCs using Tarjan
    final tarjan = Tarjan();
    final sccs = tarjan.execute(subGraphOutEdges);

    // 4. Solve the local SCCs in reverse topological order
    for (var scc in sccs) {
      _solveSCC(scc);
    }
  }

  void _solveSCC(List<String> scc) {
    for (var bfen in scc) {
      final pos = v[bfen]!;
      if (pos.assigned != null) {
        pos.computed = pos.assigned;
      } else {
        if (scc.length > 1) {
          pos.computed = const PositionEval(result: GameResult.draw, cp: 0);
        } else {
          pos.computed = null;
        }
      }
    }

    bool changed = true;
    int iterations = 0;
    while (changed) {
      changed = false;
      iterations++;
      if (iterations > 1000) {
        print("Warning: SCC local loop exceeded 1000 iterations! Breaking.");
        break;
      }

      for (var bfen in scc) {
        final pos = v[bfen]!;

        PositionEval? bestCandidate;
        for (String link in pos.links) {
          final child = v[link];
          final childEval = child?.effectiveEval;
          if (childEval == null) continue;

          final candidate = _adjustChildEval(pos, link, childEval);
          if (bestCandidate == null) {
            bestCandidate = candidate;
          } else {
            if (PositionEval.compare(candidate, bestCandidate, pos.whiteToMove) < 0) {
              bestCandidate = candidate;
            }
          }
        }

        bestCandidate ??= pos.assigned;

        if (scc.length > 1 && bestCandidate == null) {
          bestCandidate = const PositionEval(result: GameResult.draw, cp: 0);
        }

        if (pos.computed != bestCandidate) {
          pos.computed = bestCandidate;
          changed = true;
        }
      }
    }

    for (var bfen in scc) {
      final pos = v[bfen]!;
      if (pos.computed != pos._originalComputed) {
        onNodeUpdated?.call(bfen, pos.assigned, pos.computed);
      }
    }
  }

  PositionEval _adjustChildEval(Vertex pos, String linkBfen, PositionEval childEval) {
    int? newDtw = childEval.dtw != null ? childEval.dtw! + 1 : null;
    int? newDtz;
    if (childEval.dtz != null) {
      final parentPieceCount =
          pos.bfen.split(' ')[0].replaceAll(RegExp(r'[^a-zA-Z]'), '').length;
      final childPieceCount =
          linkBfen.split(' ')[0].replaceAll(RegExp(r'[^a-zA-Z]'), '').length;
      if (childPieceCount < parentPieceCount) {
        newDtz = 1;
      } else {
        newDtz = childEval.dtz! + 1;
      }
    }

    return PositionEval(
      result: childEval.result,
      dtw: newDtw,
      dtz: newDtz,
      cp: childEval.cp,
    );
  }


}

class Vertex {
  final String bfen;
  late bool whiteToMove;
  PositionEval? assigned;
  PositionEval? computed;
  PositionEval? _originalComputed;
  bool inDatabase = false;
  Set<String> links = {};
  Set<String> backLinks = {};

  PositionEval? get effectiveEval => computed ?? assigned;

  /// Legacy double getters for backward compatibility
  double? get assignedScore => assigned?.toLegacyScore();
  double? get computedScore => computed?.toLegacyScore();

  Vertex(this.bfen) {
    final parts = bfen.split(' ');
    if (parts.length > 1) {
      whiteToMove = parts[1] == 'w';
    } else {
      whiteToMove = bfen.contains(' w ');
    }
  }
}

// global graph
var graph = Graph();

void resetGraph() {
  graph = Graph();
}
