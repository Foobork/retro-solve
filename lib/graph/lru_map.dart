import 'dart:collection';

/// A bounded LRU (Least Recently Used) cache map.
///
/// When the map reaches [capacity], the oldest untouched entries are evicted
/// on subsequent insertions. All lookups, insertions, and removals operate in O(1).
class LruMap<K, V> with MapMixin<K, V> {
  int capacity;
  final LinkedHashMap<K, V> _map = LinkedHashMap<K, V>();

  LruMap({this.capacity = 50000}) {
    if (capacity < 1) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be at least 1');
    }
  }

  @override
  V? operator [](Object? key) {
    if (!_map.containsKey(key)) return null;
    // Re-insert to mark as most recently used (MRU)
    final value = _map.remove(key as K);
    _map[key] = value as V;
    return value;
  }

  @override
  void operator []=(K key, V value) {
    if (_map.containsKey(key)) {
      _map.remove(key);
    } else if (_map.length >= capacity) {
      _map.remove(_map.keys.first);
    }
    _map[key] = value;
  }

  @override
  void clear() => _map.clear();

  /// Looks up [key] without updating its position in the LRU order.
  V? peek(Object? key) => _map[key];

  @override
  Iterable<K> get keys => _map.keys.toList(growable: false);

  @override
  Iterable<V> get values => _map.values.toList(growable: false);

  @override
  Iterable<MapEntry<K, V>> get entries => _map.entries.toList(growable: false);

  @override
  V? remove(Object? key) => _map.remove(key);

  @override
  bool containsKey(Object? key) => _map.containsKey(key);

  @override
  int get length => _map.length;

  @override
  bool get isEmpty => _map.isEmpty;

  @override
  bool get isNotEmpty => _map.isNotEmpty;

  /// Returns entries in order from Least Recently Used to Most Recently Used.
  Iterable<MapEntry<K, V>> get lruEntries => _map.entries;
}
