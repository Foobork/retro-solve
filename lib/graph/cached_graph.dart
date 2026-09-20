import 'dart:async';
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
  /// 1. Discovers all upstream ancestor nodes via SQLite reverse index and memory backlinks.
  /// 2. Ensures all affected ancestor positions and their 1-ply children are in the LRU cache.
  /// 3. Contracts strongly connected components and propagates minimax evaluations upward.
  /// 4. Enqueues updated evaluations to SQLite via [onNodeUpdated].
  Future<void> solveBfenAsync(String bfen) async {
    if (dbService.isOpen) {
      await dbService.flush();
    }

    // 1. Upstream BFS searching both cache backLinks and SQLite reverse index idx_edges_target
    final upstreamNodes = <String>{bfen};
    final queue = [bfen];
    while (queue.isNotEmpty) {
      final curr = queue.removeLast();
      final inMemParents = v[curr]?.backLinks ?? const <String>{};
      final dbParents = dbService.isOpen
          ? await dbService.getParentBfens(curr)
          : const <String>[];
      final allParents = {...inMemParents, ...dbParents};
      for (final parent in allParents) {
        if (upstreamNodes.add(parent)) {
          queue.add(parent);
        }
      }
    }

    // 2. Ensure all upstream nodes are in cache
    await prefetchPositions(upstreamNodes);

    // 3. For every upstream node, ensure its children are in cache with their evaluations
    final childrenToPrefetch = <String>{};
    for (final node in upstreamNodes) {
      final dbChildren = dbService.isOpen
          ? await dbService.getChildrenBfens(node)
          : const <String>[];
      final vertex = v[node];
      if (vertex != null) {
        vertex.links.addAll(dbChildren);
      }
      final allChildren = {...?vertex?.links, ...dbChildren};
      for (final child in allChildren) {
        final childVertex = v[child];
        if (childVertex == null || childVertex.effectiveEval == null) {
          childrenToPrefetch.add(child);
        }
      }
    }
    if (childrenToPrefetch.isNotEmpty) {
      await prefetchPositions(childrenToPrefetch);
    }

    // 4. Solve the local subgraph in memory
    solveSubGraph(upstreamNodes);
  }
}
