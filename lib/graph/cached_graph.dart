import 'dart:async';
import 'dart:math';
import '../persistence/database_service.dart';
import 'graph.dart';

/// A bounded, on-demand cached graph backed by SQLite storage.
///
/// Instead of holding millions of vertices and transitions in memory,
/// [CachedGraph] retains only a bounded LRU cache of recently touched positions
/// (default 50,000 entries ~25–30 MB RAM) and queries SQLite on-demand.
class CachedGraph extends Graph {
  final DatabaseService dbService;
  final int cacheCapacity;

  CachedGraph({
    DatabaseService? dbService,
    this.cacheCapacity = 50000,
  })  : dbService = dbService ?? DatabaseService.instance,
        super(vertexMap: LruMap<String, Vertex>(capacity: cacheCapacity));

  /// Loads a single vertex by BFEN from SQLite if not present in memory.
  ///
  /// Automatically populates the vertex's outgoing links and incoming backlinks
  /// from the SQLite database. Returns `null` if the position does not exist in the database.
  Future<Vertex?> loadVertex(String bfen) async {
    if (v.containsKey(bfen)) {
      return v[bfen];
    }
    if (!dbService.isOpen) return null;

    final row = await dbService.getNode(bfen);
    if (row == null) return null;

    final assigned = DatabaseService.evalFromRow(row, 'assigned');
    final computed = DatabaseService.evalFromRow(row, 'computed');

    final vertex = addFullVertex(bfen, assigned, computed);

    final children = await dbService.getChildrenBfens(bfen);
    vertex.links.addAll(children);

    final parents = await dbService.getParentBfens(bfen);
    vertex.backLinks.addAll(parents);

    return vertex;
  }

  Future<void> prefetchPositions(Iterable<String> bfens, {bool forceRefresh = false}) async {
    if (!dbService.isOpen || bfens.isEmpty) return;
    final missing = bfens.where((b) {
      if (forceRefresh) return true;
      final existing = v[b];
      if (existing == null) return true;
      return !existing.queriedFromDb &&
          !existing.inDatabase &&
          existing.assigned == null &&
          existing.computed == null;
    }).toSet();
    if (missing.isEmpty) return;

    final rows = await dbService.getNodes(missing);
    for (final bfen in missing) {
      final row = rows[bfen];
      if (row != null) {
        final assigned = DatabaseService.evalFromRow(row, 'assigned');
        final computed = DatabaseService.evalFromRow(row, 'computed');
        addFullVertex(bfen, assigned, computed);
      } else {
        final vertex = addVertex(bfen);
        vertex.queriedFromDb = true;
      }
    }
  }

  /// Prefetches a position and its legal move target positions into the LRU cache.
  Future<void> prefetchPositionAndMoves(String bfen, List<String> childBfens) async {
    await prefetchPositions([bfen, ...childBfens]);
  }

  /// Performs full database retrograde solve using the out-of-core flat CSR Tarjan solver,
  /// and refreshes all cached positions in memory.
  Future<CsrSolveResult?> solveGlobal({
    void Function(double progress, String status)? onProgress,
  }) async {
    if (!dbService.isOpen) {
      super.solve();
      return null;
    }
    await dbService.flush();
    final result = await dbService.solveGlobalCsr(onProgress: onProgress);

    // Refresh evaluations for all currently cached positions
    final cachedBfens = v.keys.toList(growable: false);
    if (cachedBfens.isNotEmpty) {
      final rows = await dbService.getNodes(cachedBfens);
      for (final bfen in cachedBfens) {
        final vertex = v[bfen];
        final row = rows[bfen];
        if (vertex != null && row != null) {
          vertex.assigned = DatabaseService.evalFromRow(row, 'assigned');
          vertex.computed = DatabaseService.evalFromRow(row, 'computed');
          if (vertex.assigned != null || vertex.computed != null) {
            vertex.inDatabase = true;
          }
          vertex.queriedFromDb = true;
        }
      }
    }
    return result;
  }

  @override
  void solve() {
    if (dbService.isOpen) {
      solveGlobal();
    } else {
      super.solve();
    }
  }

  /// Performs targeted retrograde back-propagation through SQLite reverse index (`idx_edges_target`).
  ///
  /// Evaluates [bfen] locally first. If [bfen]'s evaluation does not change, returns immediately.
  /// If [bfen]'s evaluation changes, propagates minimax updates upward along ancestor paths
  /// where parent evaluations are actively affected.
  Future<void> solveBfenAsync(String bfen) async {
    if (dbService.isOpen) {
      await dbService.flush();
    }

    var startVertex = v[bfen];
    if (startVertex == null) {
      await prefetchPositions([bfen]);
      startVertex = v[bfen];
    }
    if (startVertex == null) return;

    if (startVertex.links.isEmpty && dbService.isOpen) {
      final dbChildren = await dbService.getChildrenBfens(bfen);
      startVertex.links.addAll(dbChildren);
    }

    if (startVertex.links.isNotEmpty) {
      final unEvaled = startVertex.links
          .where((l) => v[l] == null || v[l]?.effectiveEval == null)
          .toList();
      if (unEvaled.isNotEmpty) {
        await prefetchPositions(unEvaled);
      }
    }

    startVertex.originalComputed = startVertex.computed;
    solveSCC([bfen]);

    // If bfen's computed evaluation did not change, no ancestors can change!
    if (startVertex.computed == startVertex.originalComputed) {
      return;
    }

    // Worklist propagation: propagate changes upward only where evaluations actually change!
    final queue = <String>[bfen];
    final visitedChangeCount = <String, int>{bfen: 1};

    while (queue.isNotEmpty) {
      final curr = queue.removeAt(0);

      final inMemParents = v[curr]?.backLinks ?? const <String>{};
      final dbParents = dbService.isOpen
          ? await dbService.getParentBfens(curr)
          : const <String>[];
      final allParents = {...inMemParents, ...dbParents};
      if (allParents.isEmpty) continue;

      await prefetchPositions(allParents);

      for (final parentBfen in allParents) {
        final parentVertex = v[parentBfen];
        if (parentVertex == null) continue;

        if (parentVertex.links.isEmpty && dbService.isOpen) {
          final dbChildren = await dbService.getChildrenBfens(parentBfen);
          parentVertex.links.addAll(dbChildren);
        }

        final unEvaledChildren = parentVertex.links
            .where((l) => v[l] == null || v[l]?.effectiveEval == null)
            .toList();
        if (unEvaledChildren.isNotEmpty) {
          await prefetchPositions(unEvaledChildren);
        }

        parentVertex.originalComputed = parentVertex.computed;
        solveSCC([parentBfen]);

        if (parentVertex.computed != parentVertex.originalComputed) {
          final count = (visitedChangeCount[parentBfen] ?? 0) + 1;
          visitedChangeCount[parentBfen] = count;
          if (count <= 10) {
            queue.add(parentBfen);
          }
        }
      }
    }
  }

  @override
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
        final isWhite = pos.whiteToMove;
        final targetWin = isWhite ? GameResult.whiteWins : GameResult.blackWins;
        final targetLoss = isWhite ? GameResult.blackWins : GameResult.whiteWins;

        int winningCount = 0;
        int minWinDtw = 999999;
        PositionEval? bestWinCandidate;

        int losingCount = 0;
        int maxLoseDtw = -1;
        bool hasNullLoseDtw = false;
        PositionEval? bestLoseCandidate;

        PositionEval? bestNonDecisiveCandidate;
        bool hasDraw = false;

        for (String link in pos.links) {
          final child = v[link];
          final childEval = child?.effectiveEval;
          if (childEval == null) continue;

          final candidate = adjustChildEval(pos, link, childEval);
          if (candidate.result == targetWin) {
            winningCount++;
            final dtw = candidate.dtw;
            if (dtw != null && dtw < minWinDtw) {
              minWinDtw = dtw;
              bestWinCandidate = candidate;
            } else {
              bestWinCandidate ??= candidate;
            }
          } else if (candidate.result == targetLoss) {
            losingCount++;
            final dtw = candidate.dtw;
            if (dtw == null) {
              hasNullLoseDtw = true;
              bestLoseCandidate = candidate;
            } else if (!hasNullLoseDtw && dtw > maxLoseDtw) {
              maxLoseDtw = dtw;
              bestLoseCandidate = candidate;
            } else {
              bestLoseCandidate ??= candidate;
            }
          } else if (candidate.result == GameResult.draw) {
            hasDraw = true;
            if (bestNonDecisiveCandidate == null) {
              bestNonDecisiveCandidate = candidate;
            } else if (bestNonDecisiveCandidate.cp != null) {
              if (isWhite ? 0 > bestNonDecisiveCandidate.cp! : 0 < bestNonDecisiveCandidate.cp!) {
                bestNonDecisiveCandidate = candidate;
              }
            }
          } else if (candidate.cp != null) {
            if (bestNonDecisiveCandidate == null || bestNonDecisiveCandidate.cp == null) {
              bestNonDecisiveCandidate = candidate;
            } else {
              if (isWhite ? candidate.cp! > bestNonDecisiveCandidate.cp! : candidate.cp! < bestNonDecisiveCandidate.cp!) {
                bestNonDecisiveCandidate = candidate;
              }
            }
          }
        }

        PositionEval? bestCandidate;
        final numEdges = pos.links.length;

        if (winningCount > 0) {
          // 1. Any winning move -> Side to move WINS
          bestCandidate = bestWinCandidate;
        } else if (numEdges > 0 && losingCount == numEdges) {
          // 2. ALL moves are proven losses -> Side to move is forced to LOSE
          bestCandidate = bestLoseCandidate;
        } else if (numEdges > 0 && losingCount + (hasDraw ? 1 : 0) == numEdges && hasDraw) {
          // 3. All non-losing moves are draws -> Draw
          bestCandidate = const PositionEval(result: GameResult.draw, cp: 0);
        } else {
          // 4. Undecided / unproven
          if (bestNonDecisiveCandidate != null) {
            bestCandidate = bestNonDecisiveCandidate;
          } else if (pos.assigned != null) {
            bestCandidate = pos.assigned;
          }
        }

        if (pos.computed != bestCandidate) {
          pos.computed = bestCandidate;
          changed = true;
        }
      }
    }

    for (var bfen in scc) {
      final pos = v[bfen]!;
      if (pos.computed != pos.originalComputed) {
        onNodeUpdated?.call(bfen, pos.assigned, pos.computed);
      }
    }
  }
}
