part of chess;

class AtomicChess extends Chess {
  List<List<Piece?>> boardHistory = [];

  AtomicChess() : super() {
    clear();
  }

  @override
  bool get isAtomic => true;

  @override
  void clear() {
    super.clear();
    boardHistory.clear();
  }

  @override
  bool load(String fen) {
    final success = super.load(fen);
    if (success) {
      boardHistory.clear();
    }
    return success;
  }

  @override
  void makeMove(Move move) {
    // 1. Save current board state to history
    boardHistory.add(List<Piece?>.from(board));

    // 2. Call super.makeMove
    super.makeMove(move);

    // 3. Handle explosions if the move was a capture
    if ((move.flags & (Chess.bitsCapture | Chess.bitsEpCapture)) != 0) {
      final explodedSquares = {move.to};
      final adjacentOffsets = [-17, -16, -15, -1, 1, 15, 16, 17];
      for (final offset in adjacentOffsets) {
        final neighbor = move.to + offset;
        if ((neighbor & 0x88) == 0) {
          final piece = board[neighbor];
          if (piece != null && piece.type != pawn) {
            explodedSquares.add(neighbor);
            if (piece.type == king) {
              kings[piece.color] = -1;
            }
            board[neighbor] = null;
          }
        }
      }
      board[move.to] = null;
      if (kings[white] == move.to) kings[white] = -1;
      if (kings[black] == move.to) kings[black] = -1;

      // Update castling rights if any rooks are exploded
      for (final color in PlayerColor.values) {
        if (castling[color] != 0) {
          for (final r in Chess.rooks[color]!) {
            if (explodedSquares.contains(r['square'])) {
              if ((castling[color] & r['flag']) != 0) {
                castling[color] ^= r['flag'];
              }
            }
          }
        }
      }

      // If a king was exploded, turn off its castling rights entirely
      if (kings[white] < 0) castling[white] = 0;
      if (kings[black] < 0) castling[black] = 0;
    }
  }

  @override
  Move? undoMove() {
    if (history.isEmpty || boardHistory.isEmpty) {
      return null;
    }
    final old = history.removeLast();

    final move = old.move;
    kings = old.kings;
    turn = old.turn;
    castling = old.castling;
    epSquare = old.epSquare;
    halfMoves = old.halfMoves;
    moveNumber = old.moveNumber;
    checksCount = old.checksCount;

    board = boardHistory.removeLast();

    return move;
  }

  @override
  List<Move> generateMoves([Map? options]) {
    if (kings[white] < 0 || kings[black] < 0) {
      return [];
    }

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
      if (kings[us] >= 0 && (kings[them] < 0 || !kingAttacked(us))) {
        legalMoves.add(move);
      }
      undoMove();
    }

    return legalMoves;
  }

  @override
  bool attacked(PlayerColor color, int square) {
    if (square < 0) return false;
    final attackerKing = kings[color];
    if (attackerKing >= 0 && _areAdjacent(square, attackerKing)) {
      return false;
    }
    return super.attacked(color, square);
  }

  @override
  bool kingAttacked(PlayerColor color) {
    final myKing = kings[color];
    if (myKing < 0) return true;
    return attacked(Chess.swapColor(color), myKing);
  }

  @override
  bool get inCheckmate {
    if (kings[white] < 0 || kings[black] < 0) {
      return false;
    }
    return super.inCheckmate;
  }

  @override
  bool get inDraw {
    if (kings[white] < 0 || kings[black] < 0) {
      return false;
    }
    return super.inDraw;
  }

  @override
  bool get gameOver {
    if (kings[white] < 0 || kings[black] < 0) {
      return true;
    }
    return super.gameOver;
  }

  bool _areAdjacent(int sq1, int sq2) {
    if (sq1 < 0 || sq2 < 0) return false;
    final r1 = Chess.rank(sq1);
    final f1 = Chess.file(sq1);
    final r2 = Chess.rank(sq2);
    final f2 = Chess.file(sq2);
    return (r1 - r2).abs() <= 1 && (f1 - f2).abs() <= 1;
  }

  @override
  AtomicChess copy() {
    return AtomicChess()
      ..board = List<Piece?>.from(board)
      ..kings = ColorMap<int>.clone(kings)
      ..turn = turn
      ..castling = ColorMap<int>.clone(castling)
      ..epSquare = epSquare
      ..halfMoves = halfMoves
      ..moveNumber = moveNumber
      ..history = List<GameState>.from(history)
      ..header = Map.from(header)
      ..boardHistory = List<List<Piece?>>.from(boardHistory.map((b) => List<Piece?>.from(b)));
  }
}
