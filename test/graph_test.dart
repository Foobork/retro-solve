import 'package:retro_solve/chess/chess.dart';
import 'package:retro_solve/graph/graph.dart';
import 'package:test/test.dart';

void main() {
  test("graph addMove", () {
    var g = Graph();
    g.addLink("a w", "b b");
    expect(g.v.length, equals(2));
    expect(g.v["a w"]?.links.length, equals(1));
  });

  test("toy graph solve", () {
    var g = Graph();
    g.addLink("0 w", "d4 b");
    g.addLink("0 w", "Nf3 b");
    g.addLink("d4 b", "d4 d5 w");
    g.addLink("Nf3 b", "Nf3 d5 w");
    g.addLink("d4 d5 w", "d4 d5 Nf3 b");
    g.addLink("Nf3 d5 w", "d4 d5 Nf3 b");
    g.assign("d4 d5 Nf3 b", 0.1);
    expect(g.v.length, equals(6));
    g.solve();
  });

  void addLinks(Graph g, Chess game) {
    List<Move> moves = game.generateMoves();
    String a = game.bfen;
    for (var move in moves) {
      game.makeMove(move);
      String b = game.bfen;
      game.undo();
      g.addLink(a, b);
    }
  }

  test("chess graph solve", () {
    var g = Graph();
    var game = Chess();
    var startBfen = game.bfen;

    addLinks(g, game);
    expect(g.v.length, equals(21));
    g.solve();
    expect(g.v[startBfen]?.computed, equals(null));

    game.move("d4");
    addLinks(g, game);
    g.assign(game.bfen, 0.1);
    g.solve();
    expect(g.v[startBfen]?.computed, equals(0.1));

    game.move("d5");
    addLinks(g, game);
    g.assign(game.bfen, 0.2);
    g.solve();
    expect(g.v[startBfen]?.computed, equals(0.2));

    game.move("Nf3");
    addLinks(g, game);
    g.assign(game.bfen, 0.3);
    g.solve();
    expect(g.v[startBfen]?.computed, equals(0.3));

    game.reset();
    game.move("Nf3");
    var nf3 = game.bfen;
    addLinks(g, game);

    game.move("d5");
    addLinks(g, game);
    g.solve();
    expect(g.v[nf3]?.computed, equals(0.3));
  });
}
