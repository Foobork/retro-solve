part of chess;

class RacingKingsChess extends Chess {
  RacingKingsChess() : super() {
    clear();
  }

  @override
  bool get isRacingKings => true;

  @override
  void reset() {
    load('8/8/8/8/8/8/krbnNBRK/qrbnNBRQ w - - 0 1');
  }

  @override
  bool load(String fen) {
    final success = super.load(fen);
    if (!success) return false;
    castling[white] = 0;
    castling[black] = 0;
    return true;
  }

  bool get isRank8Draw =>
      Chess.rank(kings[white]) == Chess.rank8 &&
      Chess.rank(kings[black]) == Chess.rank8;

  bool get isRacingKingsGameOver =>
      Chess.rank(kings[black]) == Chess.rank8 ||
      (Chess.rank(kings[white]) == Chess.rank8 && turn == white);

  @override
  List<Move> generateMoves([Map? options]) {
    final legal = (options != null && options.containsKey('legal')) ? options['legal'] : true;

    if (!legal) {
      return super.generateMoves(options);
    }

    if (isRacingKingsGameOver || isRank8Draw || halfMoves >= 100 || inThreefoldRepetition) {
      return [];
    }

    final pseudoOptions = Map.from(options ?? {})..['legal'] = false;
    final moves = super.generateMoves(pseudoOptions);

    final legalMoves = <Move>[];
    final us = turn;
    final them = Chess.swapColor(us);

    for (final move in moves) {
      makeMove(move);
      if (!kingAttacked(us) && !kingAttacked(them)) {
        legalMoves.add(move);
      }
      undoMove();
    }

    return legalMoves;
  }

  @override
  bool get insufficientMaterial => false;

  @override
  bool get inStalemate {
    if (isRacingKingsGameOver || isRank8Draw) {
      return false;
    }
    return super.inStalemate;
  }

  @override
  bool get inDraw {
    if (isRank8Draw) {
      return true;
    }
    return super.inDraw;
  }

  @override
  bool get gameOver {
    if (inDraw) return true;
    if (isRacingKingsGameOver) return true;
    return generateMoves().isEmpty;
  }

  @override
  RacingKingsChess copy() {
    return RacingKingsChess()
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
