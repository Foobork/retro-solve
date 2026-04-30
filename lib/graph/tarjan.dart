import 'dart:math';

class Tarjan {
  int _index = 0;
  final Map<String, int> _indices = {};
  final Map<String, int> _lowlinks = {};
  final List<String> _stack = [];
  final Set<String> _onStack = {};
  final List<List<String>> _sccs = [];

  /// Executes Tarjan's SCC algorithm.
  /// Returns a list of SCCs (Strongly Connected Components).
  /// The SCCs are returned in reverse topological order (leaf components first),
  /// which is ideal for retrograde min-max analysis.
  List<List<String>> execute(Map<String, Iterable<String>> outEdges) {
    _index = 0;
    _indices.clear();
    _lowlinks.clear();
    _stack.clear();
    _onStack.clear();
    _sccs.clear();

    for (var node in outEdges.keys) {
      if (!_indices.containsKey(node)) {
        _strongConnect(node, outEdges);
      }
    }

    return _sccs;
  }

  void _strongConnect(String v, Map<String, Iterable<String>> outEdges) {
    _indices[v] = _index;
    _lowlinks[v] = _index;
    _index++;
    _stack.add(v);
    _onStack.add(v);

    for (var w in outEdges[v] ?? const <String>[]) {
      // Only traverse known nodes inside the outEdges context
      if (!outEdges.containsKey(w)) continue;

      if (!_indices.containsKey(w)) {
        _strongConnect(w, outEdges);
        _lowlinks[v] = min(_lowlinks[v]!, _lowlinks[w]!);
      } else if (_onStack.contains(w)) {
        _lowlinks[v] = min(_lowlinks[v]!, _indices[w]!);
      }
    }

    if (_lowlinks[v] == _indices[v]) {
      final scc = <String>[];
      String w;
      do {
        w = _stack.removeLast();
        _onStack.remove(w);
        scc.add(w);
      } while (w != v);
      _sccs.add(scc);
    }
  }
}
