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

  @override
  List<Move> generateMoves([Map? options]) {
    final legal = (options != null && options.containsKey('legal')) ? options['legal'] : true;

    if (!legal) {
      return super.generateMoves(options);
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
  bool get inDraw {
    if (Chess.rank(kings[white]) == Chess.rank8 && Chess.rank(kings[black]) == Chess.rank8) {
      return true;
    }
    return super.inDraw;
  }

  @override
  bool get gameOver {
    if (inDraw) return true;
    if (Chess.rank(kings[black]) == Chess.rank8) return true;
    if (Chess.rank(kings[white]) == Chess.rank8 && turn == white) return true;
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
      ..history = List<GameState>.from(history)
      ..header = Map.from(header);
  }
}
