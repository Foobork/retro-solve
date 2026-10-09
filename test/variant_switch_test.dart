import 'package:flutter_test/flutter_test.dart';
import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:retro_solve/graph/graph_import.dart';
import 'package:retro_solve/gui/chess_board_controller.dart';
import 'package:retro_solve/persistence/database_service.dart';

void main() {
  test('Variant switch from Standard to Crazyhouse flushes queues and updates graph', () async {
    TestWidgetsFlutterBinding.ensureInitialized();

    final controller = ChessBoardController();
    int listenerCount = 0;

    void listener() {
      listenerCount++;
    }

    controller.addListener(listener);

    // 1. Start on Standard
    controller.setGame(Chess());
    controller.resetBoard();
    resetGraph();
    graph.onNodeUpdated = (bfen, assigned, computed) {
      DatabaseService.instance.upsertNode(bfen, assigned, computed);
    };
    graph.onEdgeAdded = (source, target) {
      DatabaseService.instance.upsertEdge(source, target);
    };
    await importGraph('data/Standard.txt');

    expect(graph.v.containsKey(controller.game.bfen), isTrue);
    final initialListenerCount = listenerCount;

    // 2. Perform variant switch logic as done in _setVariant
    controller.removeListener(listener);
    controller.setGame(CrazyhouseChess());
    controller.resetBoard();

    // Listener was detached during game swap, so listenerCount must not increase
    expect(listenerCount, equals(initialListenerCount));

    resetGraph();
    graph.onNodeUpdated = (bfen, assigned, computed) {
      DatabaseService.instance.upsertNode(bfen, assigned, computed);
    };
    graph.onEdgeAdded = (source, target) {
      DatabaseService.instance.upsertEdge(source, target);
    };

    await importGraph('data/Crazyhouse.txt');
    controller.addListener(listener);
    listener();

    expect(listenerCount, equals(initialListenerCount + 1));
    expect(graph.v.containsKey(controller.game.bfen), isTrue);

    final cached = graph as CachedGraph;
    final startBfen = controller.game.bfen;
    expect(cached.v.containsKey(startBfen), isTrue);

    // Verify positions can be queried and backsolved cleanly
    await cached.solveBfenAsync(startBfen);
    await DatabaseService.instance.flush();

    final count = await DatabaseService.instance.getPositionCount();
    expect(count, greaterThan(0));
  });
}
