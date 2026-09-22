// ignore_for_file: avoid_print

import 'dart:math';

import 'cached_graph.dart';
import 'position_eval.dart';
import 'tarjan.dart';
export 'cached_graph.dart';
export 'csr_graph_solver.dart';
export 'lru_map.dart';
export 'position_eval.dart';

typedef NodeUpdateCallback = void Function(
    String bfen, PositionEval? assigned, PositionEval? computed);
typedef EdgeUpdateCallback = void Function(String fromBfen, String toBfen);

class Graph {
  /// Scores with absolute value >= mateThreshold represent forced mate evaluations.
  /// A threshold of 200.0 supports mate distances up to 400 moves (800 plies: 1000.0 - 800.0 = 200.0).
  static const double mateThreshold = 200.0;

  Map<String, Vertex> v;
  NodeUpdateCallback? onNodeUpdated;
  EdgeUpdateCallback? onEdgeAdded;

  Graph({Map<String, Vertex>? vertexMap}) : v = vertexMap ?? {};

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
    if (pos.assigned != null || pos.computed != null) {
      pos.inDatabase = true;
    }
    pos.queriedFromDb = true;
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
      solveSCC(scc);
    }
    print("solved");
  }

  /// Solves a designated subgraph defined by [upstreamNodes] using Tarjan SCC contraction.
  void solveSubGraph(Set<String> upstreamNodes) {
    Map<String, Iterable<String>> subGraphOutEdges = {};
    for (String node in upstreamNodes) {
      final vertex = v[node];
      if (vertex == null) continue;
      subGraphOutEdges[node] =
          vertex.links.where((l) => upstreamNodes.contains(l));

      vertex._originalComputed = vertex.computed;
      if (vertex.assigned == null) {
        vertex.computed = null;
      }
    }

    final tarjan = Tarjan();
    final sccs = tarjan.execute(subGraphOutEdges);

    for (var scc in sccs) {
      solveSCC(scc);
    }
  }

  void solveBfen(String bfen) {
    // Local retrograde solve for a single node's reachable subgraph
    if (!v.containsKey(bfen)) return;

    // 1. Upstream BFS to find all affected ancestor nodes
    final upstreamNodes = <String>{bfen};
    final queue = [bfen];
    while (queue.isNotEmpty) {
      final curr = queue.removeLast();
      final vertex = v[curr];
      if (vertex != null) {
        for (var parent in vertex.backLinks) {
          if (upstreamNodes.add(parent)) {
            queue.add(parent);
          }
        }
      }
    }

    // 2. Solve local subgraph in reverse topological order
    solveSubGraph(upstreamNodes);
  }

  void solveSCC(List<String> scc) {
    for (var bfen in scc) {
      final pos = v[bfen]!;
      if (pos.assigned != null) {
        pos.computed = pos.assigned;
      } else {
        pos.computed = null;
      }
    }

    bool changed = true;
    int iterations = 0;
    final int maxIterations = scc.length > 1 ? max(scc.length * 2, 20) : 5;
    while (changed) {
      changed = false;
      iterations++;
      if (iterations >= maxIterations) {
        break;
      }

      for (var bfen in scc) {
        final pos = v[bfen]!;

        PositionEval? bestCandidate;
        for (String link in pos.links) {
          final child = v[link];
          final childEval = child?.effectiveEval;
          if (childEval == null) continue;

          final candidate = adjustChildEval(pos, link, childEval);
          if (bestCandidate == null) {
            bestCandidate = candidate;
          } else {
            if (PositionEval.compare(candidate, bestCandidate, pos.whiteToMove) < 0) {
              bestCandidate = candidate;
            }
          }
        }

        bestCandidate ??= pos.assigned;

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

  PositionEval adjustChildEval(Vertex pos, String linkBfen, PositionEval childEval) {
    int? newDtw = childEval.dtw != null ? childEval.dtw! + 1 : null;

    return PositionEval(
      result: childEval.result,
      dtw: newDtw,
      cp: childEval.result == GameResult.draw ? 0 : childEval.cp,
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
  bool queriedFromDb = false;
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

// Global graph instance (uses on-demand bounded LRU cache by default)
Graph graph = CachedGraph();

void resetGraph({bool useCache = true, int cacheCapacity = 50000}) {
  graph = useCache ? CachedGraph(cacheCapacity: cacheCapacity) : Graph();
}
