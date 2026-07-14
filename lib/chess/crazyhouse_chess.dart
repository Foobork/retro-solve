part of chess;

class CrazyhouseChess extends Chess {
  late Map<PlayerColor, Map<PieceType, int>> pockets;
  late List<bool> promoted;

  CrazyhouseChess() : super() {
    clear();
  }

  @override
  bool get isCrazyhouse => true;

  @override
  void clear() {
    pockets = {
      white: {pawn: 0, knight: 0, bishop: 0, rook: 0, queen: 0},
      black: {pawn: 0, knight: 0, bishop: 0, rook: 0, queen: 0}
    };
    promoted = List<bool>.filled(128, false);
    super.clear();
  }

  @override
  void reset() {
    load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1');
  }

  @override
  bool load(String fen) {
    List tokens = fen.split(RegExp(r'\s+'));
    if (tokens.isEmpty) return false;

    String position = tokens[0];
    int bracketStart = position.indexOf('[');
    String boardPart = position;
    String pocketPart = '';
    if (bracketStart != -1) {
      boardPart = position.substring(0, bracketStart);
      int bracketEnd = position.indexOf(']');
      if (bracketEnd != -1 && bracketEnd > bracketStart) {
        pocketPart = position.substring(bracketStart + 1, bracketEnd);
      }
    }

    List<String> cleanTokens = List<String>.from(tokens);
    cleanTokens[0] = boardPart;
    final cleanFen = cleanTokens.join(' ');

    final success = super.load(cleanFen);
    if (!success) return false;

    pockets = {
      white: {pawn: 0, knight: 0, bishop: 0, rook: 0, queen: 0},
      black: {pawn: 0, knight: 0, bishop: 0, rook: 0, queen: 0}
    };
    for (var i = 0; i < pocketPart.length; i++) {
      final char = pocketPart[i];
      final color = (char == char.toUpperCase()) ? white : black;
      final type = Chess.pieceTypes[char.toLowerCase()];
      if (type != null) {
        pockets[color]![type] = (pockets[color]![type] ?? 0) + 1;
      }
    }

    promoted = List<bool>.filled(128, false);
    return true;
  }

  @override
  String generateBfen() {
    final base = super.generateBfen();
    final parts = base.split(' ');
    var boardPart = parts[0];

    String pocketStr = '';
    final pocketWhite = pockets[white]!;
    for (final type in [queen, rook, bishop, knight, pawn]) {
      final count = pocketWhite[type] ?? 0;
      pocketStr += type.name.toUpperCase() * count;
    }
    final pocketBlack = pockets[black]!;
    for (final type in [queen, rook, bishop, knight, pawn]) {
      final count = pocketBlack[type] ?? 0;
      pocketStr += type.name.toLowerCase() * count;
    }

    parts[0] = '$boardPart[$pocketStr]';
    return parts.join(' ');
  }

  @override
  List<Move> generateMoves([Map? options]) {
    final moves = super.generateMoves(options);

    final isSingleSquare = options != null && options.containsKey('square');
    if (isSingleSquare) {
      return moves;
    }

    final us = turn;
    final pocket = pockets[us]!;
    for (final type in [queen, rook, bishop, knight, pawn]) {
      final count = pocket[type] ?? 0;
      if (count > 0) {
        for (var i = Chess.squaresA8; i <= Chess.squaresH1; i++) {
          if ((i & 0x88) != 0) {
            i += 7;
            continue;
          }
          if (board[i] == null) {
            if (type == pawn && (Chess.rank(i) == Chess.rank1 || Chess.rank(i) == Chess.rank8)) {
              continue;
            }
            final dropMove = Move(us, i, i, Chess.bitsDrop, type, null, null);

            final legal = (options != null && options.containsKey('legal')) ? options['legal'] : true;
            if (legal) {
              makeMove(dropMove);
              if (!kingAttacked(us)) {
                moves.add(dropMove);
              }
              undoMove();
            } else {
              moves.add(dropMove);
            }
          }
        }
      }
    }

    return moves;
  }

  @override
  void makeMove(Move move) {
    final us = turn;
    if ((move.flags & Chess.bitsDrop) != 0) {
      push(move);
      board[move.to] = Piece(move.piece, us);
      pockets[us]![move.piece] = pockets[us]![move.piece]! - 1;
      promoted[move.to] = false;

      epSquare = null;
      halfMoves = (move.piece == pawn) ? 0 : halfMoves + 1;
      if (turn == black) {
        moveNumber++;
      }
      turn = Chess.swapColor(turn);
    } else {
      final isCapture = (move.flags & Chess.bitsCapture) != 0;
      final isEpCapture = (move.flags & Chess.bitsEpCapture) != 0;
      final PieceType? capPiece = isCapture ? (promoted[move.to] ? pawn : move.captured!) : null;

      super.makeMove(move);

      if (isCapture) {
        pockets[us]![capPiece!] = (pockets[us]![capPiece] ?? 0) + 1;
      } else if (isEpCapture) {
        pockets[us]![pawn] = (pockets[us]![pawn] ?? 0) + 1;
      }

      promoted[move.to] = ((move.flags & Chess.bitsPromotion) != 0)
          ? true
          : promoted[move.from];
      promoted[move.from] = false;
    }
  }

  @override
  Move? undoMove() {
    if (history.isEmpty) return null;

    final last = history.last;
    final move = last.move;

    if ((move.flags & Chess.bitsDrop) != 0) {
      history.removeLast();
      board[move.to] = null;

      kings = last.kings;
      turn = last.turn;
      castling = last.castling;
      epSquare = last.epSquare;
      halfMoves = last.halfMoves;
      moveNumber = last.moveNumber;
      checksCount = last.checksCount;
      pockets = last.pockets!;
      promoted = last.promoted!;
      return move;
    } else {
      final returnedMove = super.undoMove();
      pockets = last.pockets!;
      promoted = last.promoted!;
      return returnedMove;
    }
  }

  @override
  void push(Move move) {
    history.add(GameState(
      move,
      ColorMap.clone(kings),
      turn,
      ColorMap.clone(castling),
      epSquare,
      halfMoves,
      moveNumber,
      ColorMap.clone(checksCount),
      pockets.map((color, map) => MapEntry(color, Map<PieceType, int>.from(map))),
      List<bool>.from(promoted),
    ));
  }

  @override
  CrazyhouseChess copy() {
    return CrazyhouseChess()
      ..board = List<Piece?>.from(board)
      ..kings = ColorMap<int>.clone(kings)
      ..turn = turn
      ..castling = ColorMap<int>.clone(castling)
      ..epSquare = epSquare
      ..halfMoves = halfMoves
      ..moveNumber = moveNumber
      ..history = List<GameState>.from(history)
      ..header = Map.from(header)
      ..pockets = pockets.map((color, map) => MapEntry(color, Map<PieceType, int>.from(map)))
      ..promoted = List<bool>.from(promoted);
  }
}
