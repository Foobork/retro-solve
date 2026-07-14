part of chess;

class AntichessChess extends Chess {
  AntichessChess() : super() {
    clear();
  }

  @override
  bool get isAntichess => true;

  @override
  bool load(String fen) {
    final success = super.load(fen);
    if (!success) return false;
    castling[white] = 0;
    castling[black] = 0;
    return true;
  }

  @override
  void reset() {
    load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1');
  }

  @override
  List<Move> generateMoves([Map? options]) {
    final superOptions = <String, dynamic>{'legal': false};
    if (options != null && options.containsKey('square') && options['square'] != null) {
      superOptions['square'] = options['square'];
    }
    final rawMoves = super.generateMoves(superOptions);
    
    // Antichess: support promotion to King!
    final moves = <Move>[];
    for (final m in rawMoves) {
      moves.add(m);
      if ((m.flags & Chess.bitsPromotion) != 0) {
        moves.add(Move(
          m.color,
          m.from,
          m.to,
          m.flags,
          m.piece,
          m.captured,
          king, // promotion piece
        ));
      }
    }
    
    // Filter out castling moves just in case
    final nonCastleMoves = moves.where((m) => (m.flags & (Chess.bitsKsideCastle | Chess.bitsQsideCastle)) == 0).toList();

    // Antichess rule: Captures are mandatory!
    final captureMoves = nonCastleMoves.where((m) => (m.flags & (Chess.bitsCapture | Chess.bitsEpCapture)) != 0).toList();
    if (captureMoves.isNotEmpty) {
      return captureMoves;
    }
    return nonCastleMoves;
  }

  @override
  bool kingAttacked(PlayerColor color) => false;

  @override
  bool get inCheck => false;

  @override
  bool get inCheckmate => false;

  @override
  bool get inStalemate => false;

  @override
  bool get insufficientMaterial => false;

  @override
  bool get gameOver {
    return _hasNoPieces(white) || _hasNoPieces(black) || generateMoves().isEmpty || inDraw;
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
  AntichessChess copy() {
    return AntichessChess()
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
