part of chess;

class ThreeCheckChess extends Chess {
  @override
  bool get isThreeCheck => true;

  @override
  bool get isThreeCheckGameOver => checksCount[white] <= 0 || checksCount[black] <= 0;

  @override
  bool load(String fen) {
    final success = super.load(fen);
    if (!success) return false;

    List tokens = fen.split(RegExp(r'\s+'));
    bool holdsCheckCount = tokens.length == 7 && RegExp(r'^\d+\+\d+$').hasMatch(tokens[4]);
    if (holdsCheckCount) {
      final checks = tokens[4].split('+');
      checksCount[white] = int.parse(checks[0]);
      checksCount[black] = int.parse(checks[1]);
    } else {
      checksCount[white] = 3;
      checksCount[black] = 3;
    }
    return true;
  }

  @override
  String generateBfen() {
    final base = super.generateBfen();
    final checksStr = '${checksCount[white]}+${checksCount[black]}';
    return '$base $checksStr';
  }

  @override
  List<Move> generateMoves([Map? options]) {
    if (isThreeCheckGameOver) {
      return [];
    }
    return super.generateMoves(options);
  }

  @override
  void makeMove(Move move) {
    super.makeMove(move);
    if (kingAttacked(turn)) {
      final attacker = Chess.swapColor(turn);
      checksCount[attacker] = (checksCount[attacker] - 1).clamp(0, 3);
    }
  }

  @override
  void clear() {
    super.clear();
    checksCount = ColorMap(3);
  }

  @override
  ThreeCheckChess copy() {
    return ThreeCheckChess()
      ..board = List<Piece?>.from(board)
      ..kings = ColorMap<int>.clone(kings)
      ..turn = turn
      ..castling = ColorMap<int>.clone(castling)
      ..epSquare = epSquare
      ..halfMoves = halfMoves
      ..moveNumber = moveNumber
      ..history = List<GameState>.from(history)
      ..header = Map.from(header)
      ..checksCount = ColorMap<int>.clone(checksCount);
  }
}
