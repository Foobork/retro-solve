part of chess;

class HordeChess extends Chess {
  HordeChess() : super() {
    clear();
  }

  @override
  bool get isHorde => true;

  @override
  void reset() {
    load('rnbqkbnr/pppppppp/8/1PP2PP1/PPPPPPPP/PPPPPPPP/PPPPPPPP/PPPPPPPP w kq - 0 1');
  }

  @override
  bool load(String fen) {
    final success = super.load(fen);
    if (!success) return false;
    // White has no king, so castling is 0. Black might still castle.
    castling[white] = 0;
    return true;
  }

  @override
  bool kingAttacked(PlayerColor color) {
    if (color == white) return false;
    return super.kingAttacked(color);
  }

  @override
  bool attacked(PlayerColor color, int square) {
    if (square < 0) return false;
    return super.attacked(color, square);
  }

  @override
  bool get inCheck {
    if (turn == white) return false;
    return super.inCheck;
  }

  @override
  bool get inCheckmate {
    if (turn == white) return false;
    return super.inCheckmate;
  }

  @override
  bool get gameOver {
    return _hasNoPieces(white) || super.gameOver;
  }

  bool _hasNoPieces(PlayerColor color) {
    for (var i = Chess.squaresA8; i <= Chess.squaresH1; i++) {
      if ((i & 0x88) == 0 && board[i] != null && board[i]!.color == color) {
        return false;
      }
    }
    return true;
  }

  @override
  List<Move> generateMoves([Map? options]) {
    final moves = super.generateMoves(options);

    // In Horde chess, White pawns on the 1st rank can double-step to the 3rd rank.
    if (turn == white) {
      final legal = (options != null && options.containsKey('legal')) ? options['legal'] : true;
      final squareOption = (options != null && options.containsKey('square')) ? options['square'] : null;

      if (squareOption == null) {
        for (var i = Chess.squaresA1; i <= Chess.squaresH1; i++) {
          _addFirstRankDoublePush(moves, i, legal);
        }
      } else {
        final sqVal = Chess.squares[squareOption];
        if (sqVal != null && sqVal >= Chess.squaresA1 && sqVal <= Chess.squaresH1) {
          _addFirstRankDoublePush(moves, sqVal, legal);
        }
      }
    }
    return moves;
  }

  void _addFirstRankDoublePush(List<Move> moves, int from, bool legal) {
    final piece = board[from];
    if (piece != null && piece.type == pawn && piece.color == white) {
      final oneStep = from - 16;
      final twoStep = from - 32;
      if (board[oneStep] == null && board[twoStep] == null) {
        final move = buildMove(board, from, twoStep, Chess.bitsBigPawn);
        if (legal) {
          makeMove(move);
          if (!kingAttacked(white)) {
            moves.add(move);
          }
          undoMove();
        } else {
          moves.add(move);
        }
      }
    }
  }

  @override
  bool get insufficientMaterial {
    var whitePieces = 0;
    var blackPieces = 0;
    var hasPawnsQueensRooks = false;
    var whiteBishops = <int>[];
    var blackBishops = <int>[];
    var whiteKnights = 0;
    var sqColor = 0;

    for (var i = Chess.squaresA8; i <= Chess.squaresH1; i++) {
      sqColor = (sqColor + 1) % 2;
      if ((i & 0x88) != 0) {
        i += 7;
        continue;
      }
      final piece = board[i];
      if (piece != null) {
        if (piece.type == pawn || piece.type == queen || piece.type == rook) {
          hasPawnsQueensRooks = true;
        }
        if (piece.color == white) {
          whitePieces++;
          if (piece.type == bishop) whiteBishops.add(sqColor);
          if (piece.type == knight) whiteKnights++;
        } else {
          blackPieces++;
          if (piece.type == bishop) blackBishops.add(sqColor);
        }
      }
    }

    if (hasPawnsQueensRooks) return false;

    // If White has no pieces, game is already over (Black wins).
    if (whitePieces == 0) return false;

    // If Black has only a King (blackPieces == 1):
    if (blackPieces == 1) {
      // White needs enough material to checkmate a lone king without a white king.
      // Can White checkmate with a single bishop or knight? No.
      if (whitePieces == 1 && (whiteBishops.length == 1 || whiteKnights == 1)) {
        return true;
      }
      // Can White checkmate with two bishops on the same color? No.
      if (whiteBishops.length == 2 && whiteBishops.first == whiteBishops.last) {
        return true;
      }
      return false;
    }

    return super.insufficientMaterial;
  }

  @override
  HordeChess copy() {
    return HordeChess()
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
