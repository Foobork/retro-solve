// ignore_for_file: avoid_print

import 'dart:math';
import 'tarjan.dart';

typedef NodeUpdateCallback = void Function(
    String bfen, double? assigned, double? computed);
typedef EdgeUpdateCallback = void Function(String fromBfen, String toBfen);

class Graph {
  final Map<String, Vertex> v = {};
  NodeUpdateCallback? onNodeUpdated;
  EdgeUpdateCallback? onEdgeAdded;

  Vertex addVertex(String bfen) {
    return v.putIfAbsent(bfen, () => Vertex(bfen));
  }

  Vertex addFullVertex(String bfen, double? assigned, double? computed) {
    Vertex pos = v.putIfAbsent(bfen, () => Vertex(bfen));
    pos.assigned = assigned;
    pos.computed = computed;
    pos.inDatabase = true;
    return pos;
  }

  void addLink(String a, String b) {
    addVertex(a).links.add(b);
    addVertex(b).backLinks.add(a);
    onEdgeAdded?.call(a, b);
  }

  void assign(String bfen, double? eval) {
    final pos = v[bfen];
    if (pos == null) return;
    pos.assigned = eval;
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
    var vertex = v[bfen];
    if (vertex == null) return;

    // 1. Upstream BFS to find all affected ancestor nodes
    Set<String> ancestors = {bfen};
    List<String> queue = [bfen];
    while (queue.isNotEmpty) {
      String current = queue.removeLast();
      for (String backLink in v[current]!.backLinks) {
        if (ancestors.add(backLink)) {
          queue.add(backLink);
        }
      }
    }

    // 2. Build local subgraph of outEdges & reset computed values
    Map<String, Iterable<String>> subGraphOutEdges = {};
    for (String node in ancestors) {
      subGraphOutEdges[node] =
          v[node]!.links.where((l) => ancestors.contains(l));

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
          pos.computed = 0.0;
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

        double? eval;
        for (String link in pos.links) {
          double? linkEval = v[link]?.computed ?? v[link]?.assigned;
          if (linkEval == null) continue;
          double adjustedLinkEval = _adjustMateScore(linkEval);

          if (eval == null) {
            eval = adjustedLinkEval;
          } else {
            eval = pos.whiteToMove
                ? max(eval, adjustedLinkEval)
                : min(eval, adjustedLinkEval);
          }
        }

        eval ??= pos.assigned;

        if (scc.length > 1 && eval == null) {
          eval = 0.0;
        }

        if (pos.computed != eval) {
          pos.computed = eval;
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

  double _adjustMateScore(double eval) {
    const double mateThreshold = 900.0;
    if (eval > mateThreshold) {
      return eval - 1.0; // Increase mate distance for white mates
    } else if (eval < -mateThreshold) {
      return eval + 1.0; // Increase mate distance for black mates
    }
    return eval;
  }
}

class Vertex {
  late bool whiteToMove;
  double? assigned;
  double? computed;
  double? _originalComputed;
  bool inDatabase = false;
  Set<String> links = {};
  Set<String> backLinks = {};

  Vertex(String bfen) {
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
