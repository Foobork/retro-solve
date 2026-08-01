part of chess;

class KothChess extends Chess {
  @override
  bool get isKoth => true;

  bool get isKothGameOver {
    final wKing = kings[white];
    final bKing = kings[black];
    return wKing == 51 || wKing == 52 || wKing == 67 || wKing == 68 ||
           bKing == 51 || bKing == 52 || bKing == 67 || bKing == 68;
  }

  @override
  bool get gameOver => super.gameOver || isKothGameOver;

  @override
  List<Move> generateMoves([Map? options]) {
    if (isKothGameOver) {
      return [];
    }
    return super.generateMoves(options);
  }

  @override
  KothChess copy() {
    return KothChess()
      ..board = List<Piece?>.from(board)
      ..kings = ColorMap<int>.clone(kings)
      ..turn = turn
      ..castling = ColorMap<int>.clone(castling)
      ..epSquare = epSquare
      ..halfMoves = halfMoves
      ..moveNumber = moveNumber
      ..history = history.map(GameState.clone).toList()
      ..header = Map.from(header);
  }
}
