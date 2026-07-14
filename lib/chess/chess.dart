// ignore_for_file: avoid_print

library chess;

part 'three_check_chess.dart';
part 'koth_chess.dart';

/*  Copyright (c) 2014, David Kopec (my first name at oaksnow dot com)
 *  Released under the MIT license
 *  https://github.com/davecom/chess.dart/blob/master/LICENSE
 *
 *  Based on chess.js
 *  Copyright (c) 2013, Jeff Hlywa (jhlywa@gmail.com)
 *  Released under the BSD license
 *  https://github.com/jhlywa/chess.js/blob/master/LICENSE
 */

const PlayerColor black = PlayerColor.black;
const PlayerColor white = PlayerColor.white;

const PieceType pawn = PieceType.pawn;
const PieceType knight = PieceType.knight;
const PieceType bishop = PieceType.bishop;
const PieceType rook = PieceType.rook;
const PieceType queen = PieceType.queen;
const PieceType king = PieceType.king;

class Chess {
  // Constants/Class Variables

  static const Map<String, PieceType> pieceTypes = {
    'p': pawn,
    'n': knight,
    'b': bishop,
    'r': rook,
    'q': queen,
    'k': king
  };

  static const String symbols = 'pnbrqkPNBRQK';

  static const String defaultPosition = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

  static const List possibleResults = ['1-0', '0-1', '1/2-1/2', '*'];

  static const Map<PlayerColor, List<int>> pawnOffsets = {
    black: [16, 32, 17, 15],
    white: [-16, -32, -17, -15]
  };

  static const Map<PieceType, List<int>> pieceOffsets = {
    knight: [-18, -33, -31, -14, 18, 33, 31, 14],
    bishop: [-17, -15, 17, 15],
    rook: [-16, 1, 16, -1],
    queen: [-17, -16, -15, 1, 17, 16, 15, -1],
    king: [-17, -16, -15, 1, 17, 16, 15, -1]
  };

  static const List attacks = [
    // prevent aggressive reformat
    20, 0, 0, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0, 20, 0,
    0, 20, 0, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 20, 0, 0,
    0, 0, 20, 0, 0, 0, 0, 24, 0, 0, 0, 0, 20, 0, 0, 0,
    0, 0, 0, 20, 0, 0, 0, 24, 0, 0, 0, 20, 0, 0, 0, 0,
    0, 0, 0, 0, 20, 0, 0, 24, 0, 0, 20, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 20, 2, 24, 2, 20, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 2, 53, 56, 53, 2, 0, 0, 0, 0, 0, 0,
    24, 24, 24, 24, 24, 24, 56, 0, 56, 24, 24, 24, 24, 24, 24, 0,
    0, 0, 0, 0, 0, 2, 53, 56, 53, 2, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 20, 2, 24, 2, 20, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 20, 0, 0, 24, 0, 0, 20, 0, 0, 0, 0, 0,
    0, 0, 0, 20, 0, 0, 0, 24, 0, 0, 0, 20, 0, 0, 0, 0,
    0, 0, 20, 0, 0, 0, 0, 24, 0, 0, 0, 0, 20, 0, 0, 0,
    0, 20, 0, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 20, 0, 0,
    20, 0, 0, 0, 0, 0, 0, 24, 0, 0, 0, 0, 0, 0, 20
  ];

  static const List<int> rays = [
    // prevent aggressive reformat
    17, 0, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 0, 15, 0,
    0, 17, 0, 0, 0, 0, 0, 16, 0, 0, 0, 0, 0, 15, 0, 0,
    0, 0, 17, 0, 0, 0, 0, 16, 0, 0, 0, 0, 15, 0, 0, 0,
    0, 0, 0, 17, 0, 0, 0, 16, 0, 0, 0, 15, 0, 0, 0, 0,
    0, 0, 0, 0, 17, 0, 0, 16, 0, 0, 15, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 17, 0, 16, 0, 15, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 17, 16, 15, 0, 0, 0, 0, 0, 0, 0,
    1, 1, 1, 1, 1, 1, 1, 0, -1, -1, -1, -1, -1, -1, -1, 0,
    0, 0, 0, 0, 0, 0, -15, -16, -17, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, -15, 0, -16, 0, -17, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, -15, 0, 0, -16, 0, 0, -17, 0, 0, 0, 0, 0,
    0, 0, 0, -15, 0, 0, 0, -16, 0, 0, 0, -17, 0, 0, 0, 0,
    0, 0, -15, 0, 0, 0, 0, -16, 0, 0, 0, 0, -17, 0, 0, 0,
    0, -15, 0, 0, 0, 0, 0, -16, 0, 0, 0, 0, 0, -17, 0, 0,
    -15, 0, 0, 0, 0, 0, 0, -16, 0, 0, 0, 0, 0, 0, -17
  ];

  static const Map<String, String> moveFlags = {
    'NORMAL': 'n',
    'CAPTURE': 'c',
    'BIG_PAWN': 'b',
    'EP_CAPTURE': 'e',
    'PROMOTION': 'p',
    'KSIDE_CASTLE': 'k',
    'QSIDE_CASTLE': 'q'
  };

  static const Map<String, int> bits = {
    'NORMAL': bitsNormal,
    'CAPTURE': bitsCapture,
    'BIG_PAWN': bitsBigPawn,
    'EP_CAPTURE': bitsEpCapture,
    'PROMOTION': bitsPromotion,
    'KSIDE_CASTLE': bitsKsideCastle,
    'QSIDE_CASTLE': bitsQsideCastle
  };

  static const int bitsNormal = 1;
  static const int bitsCapture = 2;
  static const int bitsBigPawn = 4;
  static const int bitsEpCapture = 8;
  static const int bitsPromotion = 16;
  static const int bitsKsideCastle = 32;
  static const int bitsQsideCastle = 64;

  static const int rank1 = 7;
  static const int rank2 = 6;
  static const int rank3 = 5;
  static const int rank4 = 4;
  static const int rank5 = 3;
  static const int rank6 = 2;
  static const int rank7 = 1;
  static const int rank8 = 0;

  static const Map squares = {
    // prevent aggressive reformat
    'a8': 0, 'b8': 1, 'c8': 2, 'd8': 3, 'e8': 4, 'f8': 5, 'g8': 6, 'h8': 7,
    'a7': 16, 'b7': 17, 'c7': 18, 'd7': 19, 'e7': 20, 'f7': 21, 'g7': 22, 'h7': 23,
    'a6': 32, 'b6': 33, 'c6': 34, 'd6': 35, 'e6': 36, 'f6': 37, 'g6': 38, 'h6': 39,
    'a5': 48, 'b5': 49, 'c5': 50, 'd5': 51, 'e5': 52, 'f5': 53, 'g5': 54, 'h5': 55,
    'a4': 64, 'b4': 65, 'c4': 66, 'd4': 67, 'e4': 68, 'f4': 69, 'g4': 70, 'h4': 71,
    'a3': 80, 'b3': 81, 'c3': 82, 'd3': 83, 'e3': 84, 'f3': 85, 'g3': 86, 'h3': 87,
    'a2': 96, 'b2': 97, 'c2': 98, 'd2': 99, 'e2': 100, 'f2': 101, 'g2': 102, 'h2': 103,
    'a1': 112, 'b1': 113, 'c1': 114, 'd1': 115, 'e1': 116, 'f1': 117, 'g1': 118, 'h1': 119
  };

  static const int squaresA1 = 112;
  static const int squaresA8 = 0;
  static const int squaresH1 = 119;
  static const int squaresH8 = 7;

  static final Map<PlayerColor, List> rooks = {
    white: [
      {'square': squaresA1, 'flag': bitsQsideCastle},
      {'square': squaresH1, 'flag': bitsKsideCastle}
    ],
    black: [
      {'square': squaresA8, 'flag': bitsQsideCastle},
      {'square': squaresH8, 'flag': bitsKsideCastle}
    ]
  };

  // Instance Variables
  List<Piece?> board = []..length = 128;
  ColorMap<int> kings = ColorMap(-1);
  PlayerColor turn = white;
  ColorMap<int> castling = ColorMap(0);
  int? epSquare;
  int halfMoves = 0;
  int moveNumber = 1;
  List<GameState> history = [];
  Map header = {};

  bool get isThreeCheck => false;
  ColorMap<int> checksCount = ColorMap(3);

  /// By default start with the standard chess starting position
  Chess() {
    load(defaultPosition);
  }

  /// Start with a position from a FEN
  Chess.fromFEN(String fen) {
    load(fen);
  }

  /// Deep copy of the current Chess instance
  Chess copy() {
    return Chess()
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

  /// Reset all of the instance variables
  void clear() {
    board = []..length = 128;
    kings = ColorMap(-1);
    turn = white;
    castling = ColorMap(0);
    epSquare = null;
    halfMoves = 0;
    moveNumber = 1;
    history = [];
    header = {};
    checksCount = ColorMap(3);
    updateSetup(generateFen());
  }

  /// Go back to the chess starting position
  void reset() {
    if (isThreeCheck) {
      load('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 3+3 0 1');
    } else {
      load(defaultPosition);
    }
  }

  /// Load a position from a FEN String
  bool load(String fen) {
    List tokens = fen.split(RegExp(r'\s+'));
    String position = tokens[0];
    var square = 0;

    final validMap = validateFen(fen);
    if (!validMap['valid']) {
      print(validMap['error']);
      return false;
    }

    clear();
    bool holdsCheckCount = tokens.length == 7 && RegExp(r'^\d+\+\d+$').hasMatch(tokens[4]);

    int halfMoveIndex = holdsCheckCount ? 5 : 4;
    int fullMoveIndex = holdsCheckCount ? 6 : 5;

    for (var i = 0; i < position.length; i++) {
      final piece = position[i];

      if (piece == '/') {
        square += 8;
      } else if (isDigit(piece)) {
        square += int.parse(piece);
      } else {
        var color = (piece == piece.toUpperCase()) ? white : black;
        var type = pieceTypes[piece.toLowerCase()]!;
        put(Piece(type, color), algebraic(square));
        square++;
      }
    }

    if (tokens[1] == 'w') {
      turn = white;
    } else {
      assert(tokens[1] == 'b');
      turn = black;
    }

    if (tokens[2].indexOf('K') > -1) {
      castling[white] |= bitsKsideCastle;
    }
    if (tokens[2].indexOf('Q') > -1) {
      castling[white] |= bitsQsideCastle;
    }
    if (tokens[2].indexOf('k') > -1) {
      castling[black] |= bitsKsideCastle;
    }
    if (tokens[2].indexOf('q') > -1) {
      castling[black] |= bitsQsideCastle;
    }

    epSquare = (tokens[3] == '-') ? null : squares[tokens[3]];
    halfMoves = int.parse(tokens[halfMoveIndex]);
    moveNumber = int.parse(tokens[fullMoveIndex]);

    updateSetup(generateFen());

    return true;
  }

  /// Check the formatting of a FEN String is correct
  /// Returns a Map with keys valid, error_number, and error
  static Map validateFen(fen) {
    const errors = {
      0: 'No errors.',
      1: 'FEN string must contain six space-delimited fields.',
      2: '6th field (move number) must be a positive integer.',
      3: '5th field (half move counter) must be a non-negative integer.',
      4: '4th field (en-passant square) is invalid.',
      5: '3rd field (castling availability) is invalid.',
      6: '2nd field (side to move) is invalid.',
      7: '1st field (piece positions) does not contain 8 \'/\'-delimited rows.',
      8: '1st field (piece positions) is invalid [consecutive numbers].',
      9: '1st field (piece positions) is invalid [invalid piece].',
      10: '1st field (piece positions) is invalid [row too large].',
    };

    /* 1st criterion: 6 or 7 space-separated fields? */
    List tokens = fen.split(RegExp(r'\s+'));
    bool holdsCheckCount = tokens.length == 7 && RegExp(r'^\d+\+\d+$').hasMatch(tokens[4]);
    if (tokens.length != 6 && !holdsCheckCount) {
      return {'valid': false, 'error_number': 1, 'error': errors[1]};
    }

    int halfMoveIndex = holdsCheckCount ? 5 : 4;
    int fullMoveIndex = holdsCheckCount ? 6 : 5;

    /* 2nd criterion: move number field is a integer value > 0? */
    var temp = int.tryParse(tokens[fullMoveIndex]);
    if (temp != null) {
      if (temp <= 0) {
        return {'valid': false, 'error_number': 2, 'error': errors[2]};
      }
    } else {
      return {'valid': false, 'error_number': 2, 'error': errors[2]};
    }

    /* 3rd criterion: half move counter is an integer >= 0? */
    temp = int.tryParse(tokens[halfMoveIndex]);
    if (temp != null) {
      if (temp < 0) {
        return {'valid': false, 'error_number': 3, 'error': errors[3]};
      }
    } else {
      return {'valid': false, 'error_number': 3, 'error': errors[3]};
    }

    /* 4th criterion: 4th field is a valid e.p.-string? */
    final check4 = RegExp(r'^(-|[abcdefgh][36])$');
    if (check4.firstMatch(tokens[3]) == null) {
      return {'valid': false, 'error_number': 4, 'error': errors[4]};
    }

    /* 5th criterion: 3th field is a valid castle-string? */
    final check5 = RegExp(r'^(KQ?k?q?|Qk?q?|kq?|q|-)$');
    if (check5.firstMatch(tokens[2]) == null) {
      return {'valid': false, 'error_number': 5, 'error': errors[5]};
    }

    /* 6th criterion: 2nd field is "w" (white) or "b" (black)? */
    var check6 = RegExp(r'^([wb])$');
    if (check6.firstMatch(tokens[1]) == null) {
      return {'valid': false, 'error_number': 6, 'error': errors[6]};
    }

    /* 7th criterion: 1st field contains 8 rows? */
    List rows = tokens[0].split('/');
    if (rows.length != 8) {
      return {'valid': false, 'error_number': 7, 'error': errors[7]};
    }

    /* 8th criterion: every row is valid? */
    for (var i = 0; i < rows.length; i++) {
      /* check for right sum of fields AND not two numbers in succession */
      var sumFields = 0;
      var previousWasNumber = false;

      for (var k = 0; k < rows[i].length; k++) {
        final temp2 = int.tryParse(rows[i][k]);
        if (temp2 != null) {
          if (previousWasNumber) {
            return {'valid': false, 'error_number': 8, 'error': errors[8]};
          }
          sumFields += temp2;
          previousWasNumber = true;
        } else {
          final checkOM = RegExp(r'^[prnbqkPRNBQK]$');
          if (checkOM.firstMatch(rows[i][k]) == null) {
            return {'valid': false, 'error_number': 9, 'error': errors[9]};
          }
          sumFields += 1;
          previousWasNumber = false;
        }
      }

      if (sumFields != 8) {
        return {'valid': false, 'error_number': 10, 'error': errors[10]};
      }
    }

    /* everything's okay! */
    return {'valid': true, 'error_number': 0, 'error': errors[0]};
  }

  /// Returns a BFEN String representing the current position
  String generateBfen() {
    var empty = 0;
    var fen = '';

    for (var i = squaresA8; i <= squaresH1; i++) {
      if (board[i] == null) {
        empty++;
      } else {
        if (empty > 0) {
          fen += empty.toString();
          empty = 0;
        }
        var color = board[i]!.color;
        PieceType? type = board[i]!.type;

        fen += (color == white) ? type.toUpperCase() : type.toLowerCase();
      }

      if (((i + 1) & 0x88) != 0) {
        if (empty > 0) {
          fen += empty.toString();
        }

        if (i != squaresH1) {
          fen += '/';
        }

        empty = 0;
        i += 8;
      }
    }

    var cflags = '';
    if ((castling[white] & bitsKsideCastle) != 0) {
      cflags += 'K';
    }
    if ((castling[white] & bitsQsideCastle) != 0) {
      cflags += 'Q';
    }
    if ((castling[black] & bitsKsideCastle) != 0) {
      cflags += 'k';
    }
    if ((castling[black] & bitsQsideCastle) != 0) {
      cflags += 'q';
    }

    /* do we have an empty castling flag? */
    if (cflags == '') {
      cflags = '-';
    }
    final epflags = (epSquare == null) ? '-' : algebraic(epSquare!);
    final turnStr = (turn == white) ? 'w' : 'b';

    return [fen, turnStr, cflags, epflags].join(' ');
  }

  /// Returns a FEN String representing the current position
  String generateFen() {
    return [generateBfen(), halfMoves, moveNumber].join(' ');
  }

  /// Updates [header] with the List of args and returns it
  Map setHeader(args) {
    for (var i = 0; i < args.length; i += 2) {
      if (args[i] is String && args[i + 1] is String) {
        header[args[i]] = args[i + 1];
      }
    }
    return header;
  }

  /// called when the initial board setup is changed with put() or remove().
  /// modifies the SetUp and FEN properties of the header object.  if the FEN is
  /// equal to the default position, the SetUp and FEN are deleted
  /// the setup is only updated if history.length is zero, ie moves haven't been
  /// made.
  void updateSetup(String fen) {
    if (history.isNotEmpty) return;

    if (fen != defaultPosition) {
      header['SetUp'] = '1';
      header['FEN'] = fen;
    } else {
      header.remove('SetUp');
      header.remove('FEN');
    }
  }

  /// Returns the piece at the square in question or null
  /// if there is none
  Piece? get(String square) {
    return board[squares[square]];
  }

  /// Put [piece] on [square]
  bool put(Piece piece, String square) {
    /* check for piece */
    if (!symbols.contains(piece.type.toLowerCase())) {
      return false;
    }

    /* check for valid square */
    if (!(squares.containsKey(square))) {
      return false;
    }

    int sq = squares[square];
    board[sq] = piece;
    if (piece.type == king) {
      kings[piece.color] = sq;
    }

    updateSetup(generateFen());

    return true;
  }

  /// Removes a piece from a square and returns it,
  /// or null if none is present
  Piece? remove(String square) {
    final piece = get(square);
    board[squares[square]] = null;
    if (piece != null && piece.type == king) {
      kings[piece.color] = -1;
    }

    updateSetup(generateFen());

    return piece;
  }

  Move buildMove(List<Piece?> board, from, to, flags, [PieceType? promotion]) {
    if (promotion != null) {
      flags |= bitsPromotion;
    }

    PieceType? captured;
    final toPiece = board[to];
    if (toPiece != null) {
      captured = toPiece.type;
    } else if ((flags & bitsEpCapture) != 0) {
      captured = pawn;
    }
    return Move(turn, from, to, flags, board[from]!.type, captured, promotion);
  }

  List<Move> generateMoves([Map? options]) {

    void addMove(List<Piece?> board, List<Move> moves, from, to, flags) {
      /* if pawn promotion */
      if (board[from]!.type == pawn && (rank(to) == rank8 || rank(to) == rank1)) {
        const pieces = [queen, rook, bishop, knight];
        for (var i = 0, len = pieces.length; i < len; i++) {
          moves.add(buildMove(board, from, to, flags, pieces[i]));
        }
      } else {
        moves.add(buildMove(board, from, to, flags));
      }
    }

    final moves = <Move>[];
    final us = turn;
    final them = swapColor(us);
    final secondRank = ColorMap<int>(0);
    secondRank[black] = rank7;
    secondRank[white] = rank2;

    var firstSq = squaresA8;
    var lastSq = squaresH1;
    var singleSquare = false;

    /* do we want legal moves? */
    final legal = (options != null && options.containsKey('legal')) ? options['legal'] : true;

    /* are we generating moves for a single square? */
    if (options != null && options.containsKey('square')) {
      if (squares.containsKey(options['square'])) {
        firstSq = lastSq = squares[options['square']];
        singleSquare = true;
      } else {
        /* invalid square */
        return [];
      }
    }

    for (var i = firstSq; i <= lastSq; i++) {
      /* did we run off the end of the board */
      if ((i & 0x88) != 0) {
        i += 7;
        continue;
      }

      final piece = board[i];
      if (piece == null || piece.color != us) {
        continue;
      }

      if (piece.type == pawn) {
        /* single square, non-capturing */
        final square = i + pawnOffsets[us]![0];
        if (board[square] == null) {
          addMove(board, moves, i, square, bitsNormal);

          /* double square */
          final square2 = i + pawnOffsets[us]![1];
          if (secondRank[us] == rank(i) && board[square2] == null) {
            addMove(board, moves, i, square2, bitsBigPawn);
          }
        }

        /* pawn captures */
        for (var j = 2; j < 4; j++) {
          var square = i + pawnOffsets[us]![j];
          if ((square & 0x88) != 0) continue;

          if (board[square] != null && board[square]!.color == them) {
            addMove(board, moves, i, square, bitsCapture);
          } else if (square == epSquare) {
            addMove(board, moves, i, epSquare, bitsEpCapture);
          }
        }
      } else {
        for (var j = 0, len = pieceOffsets[piece.type]!.length; j < len; j++) {
          final offset = pieceOffsets[piece.type]![j];
          var square = i;

          while (true) {
            square += offset;
            if ((square & 0x88) != 0) break;

            if (board[square] == null) {
              addMove(board, moves, i, square, bitsNormal);
            } else {
              if (board[square]!.color == us) {
                break;
              }
              addMove(board, moves, i, square, bitsCapture);
              break;
            }

            /* break, if knight or king */
            if (piece.type == knight || piece.type == king) break;
          }
        }
      }
    }

    // check for castling if: a) we're generating all moves, or b) we're doing
    // single square move generation on the king's square
    if ((!singleSquare) || lastSq == kings[us]) {
      /* king-side castling */
      if ((castling[us] & bitsKsideCastle) != 0) {
        final castlingFrom = kings[us];
        final castlingTo = castlingFrom + 2;

        if (board[castlingFrom + 1] == null &&
            board[castlingTo] == null &&
            !attacked(them, kings[us]) &&
            !attacked(them, castlingFrom + 1) &&
            !attacked(them, castlingTo)) {
          addMove(board, moves, kings[us], castlingTo, bitsKsideCastle);
        }
      }

      /* queen-side castling */
      if ((castling[us] & bitsQsideCastle) != 0) {
        final castlingFrom = kings[us];
        final castlingTo = castlingFrom - 2;

        if (board[castlingFrom - 1] == null &&
            board[castlingFrom - 2] == null &&
            board[castlingFrom - 3] == null &&
            !attacked(them, kings[us]) &&
            !attacked(them, castlingFrom - 1) &&
            !attacked(them, castlingTo)) {
          addMove(board, moves, kings[us], castlingTo, bitsQsideCastle);
        }
      }
    }

    /* return all pseudo-legal moves (this includes moves that allow the king
     * to be captured)
     */
    if (!legal) {
      return moves;
    }

    /* filter out illegal moves */
    final legalMoves = <Move>[];
    for (var i = 0, len = moves.length; i < len; i++) {
      makeMove(moves[i]);
      if (!kingAttacked(us)) {
        legalMoves.add(moves[i]);
      }
      undoMove();
    }

    return legalMoves;
  }

  /// Convert a move from 0x88 coordinates to Standard Algebraic Notation(SAN)
  String moveToSan(Move move) {
    var output = '';
    final flags = move.flags;
    if ((flags & bitsKsideCastle) != 0) {
      output = 'O-O';
    } else if ((flags & bitsQsideCastle) != 0) {
      output = 'O-O-O';
    } else {
      var disambiguator = getDisambiguator(move);

      if (move.piece != pawn) {
        output += move.piece.toUpperCase() + disambiguator;
      }

      if ((flags & (bitsCapture | bitsEpCapture)) != 0) {
        if (move.piece == pawn) {
          output += move.fromAlgebraic[0];
        }
        output += 'x';
      }

      output += move.toAlgebraic;

      if ((flags & bitsPromotion) != 0) {
        output += '=' + move.promotion!.toUpperCase();
      }
    }

    makeMove(move);
    if (inCheck) {
      if (inCheckmate) {
        output += '#';
      } else {
        output += '+';
      }
    }
    undoMove();

    return output;
  }

  bool attacked(PlayerColor color, int square) {
    for (var i = squaresA8; i <= squaresH1; i++) {
      /* did we run off the end of the board */
      if ((i & 0x88) != 0) {
        i += 7;
        continue;
      }

      /* if empty square or wrong color */
      final piece = board[i];
      if (piece == null || piece.color != color) continue;

      final difference = i - square;
      final index = difference + 119;
      final type = piece.type;

      if ((attacks[index] & (1 << type.shift)) != 0) {
        if (type == pawn) {
          if (difference > 0) {
            if (color == white) return true;
          } else {
            if (color == black) return true;
          }
          continue;
        }

        /* if the piece is a knight or a king */
        if (type == knight || type == king) return true;

        final offset = rays[index];
        var j = i + offset;

        var blocked = false;
        while (j != square) {
          if (board[j] != null) {
            blocked = true;
            break;
          }
          j += offset;
        }

        if (!blocked) return true;
      }
    }

    return false;
  }

  bool kingAttacked(PlayerColor color) {
    return attacked(swapColor(color), kings[color]);
  }

  bool get inCheck {
    return kingAttacked(turn);
  }

  bool get inCheckmate {
    return inCheck && generateMoves().isEmpty;
  }

  bool get inStalemate {
    return !inCheck && generateMoves().isEmpty;
  }

  bool get insufficientMaterial {
    final pieces = {};
    final bishops = <int>[];
    var numPieces = 0;
    var sqColor = 0;

    for (var i = squaresA8; i <= squaresH1; i++) {
      sqColor = (sqColor + 1) % 2;
      if ((i & 0x88) != 0) {
        i += 7;
        continue;
      }

      var piece = board[i];
      if (piece != null) {
        pieces[piece.type] = (pieces.containsKey(piece.type)) ? pieces[piece.type] + 1 : 1;
        if (piece.type == bishop) {
          bishops.add(sqColor);
        }
        numPieces++;
      }
    }

    /* k vs. k */
    if (numPieces == 2) {
      return true;
    } /* k vs. kn .... or .... k vs. kb */
    else if (numPieces == 3 && (pieces[bishop] == 1 || pieces[knight] == 1)) {
      return true;
    } /* kb vs. kb where any number of bishops are all on the same color */
    else if (pieces.containsKey(bishop) && numPieces == (pieces[bishop] + 2)) {
      var sum = 0;
      var len = bishops.length;
      for (var i = 0; i < len; i++) {
        sum += bishops[i];
      }
      if (sum == 0 || sum == len) {
        return true;
      }
    }

    return false;
  }

  bool get inThreefoldRepetition {
    /* A better implementation would use a Zobrist key (instead of FEN).
     * The Zobrist key would be maintained in the make_move/undo_move functions.
     */
    final positions = {};
    var moves = [];
    var repetition = false;

    while (true) {
      var move = undoMove();
      if (move == null) {
        break;
      }
      moves.add(move);
    }

    while (true) {
      /* remove the last two fields in the FEN string, they're not needed
       * when checking for draw by rep */
      var fen = generateFen().split(' ').sublist(0, 4).join(' ');

      /* has the position occurred three or move times */
      positions[fen] = (positions.containsKey(fen)) ? positions[fen] + 1 : 1;
      if (positions[fen] >= 3) {
        repetition = true;
      }

      if (moves.isEmpty) {
        break;
      }
      makeMove(moves.removeLast());
    }

    return repetition;
  }

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
    ));
  }

  void makeMove(Move move) {
    final us = turn;
    final them = swapColor(us);
    push(move);

    board[move.to] = board[move.from];
    board[move.from] = null;

    /* if ep capture, remove the captured pawn */
    if ((move.flags & bitsEpCapture) != 0) {
      if (turn == black) {
        board[move.to - 16] = null;
      } else {
        board[move.to + 16] = null;
      }
    }

    /* if pawn promotion, replace with new piece */
    if ((move.flags & bitsPromotion) != 0) {
      board[move.to] = Piece(move.promotion!, us);
    }

    /* if we moved the king */
    if (board[move.to]!.type == king) {
      kings[board[move.to]!.color] = move.to;

      /* if we castled, move the rook next to the king */
      if ((move.flags & bitsKsideCastle) != 0) {
        final castlingTo = move.to - 1;
        final castlingFrom = move.to + 1;
        board[castlingTo] = board[castlingFrom];
        board[castlingFrom] = null;
      } else if ((move.flags & bitsQsideCastle) != 0) {
        final castlingTo = move.to + 1;
        final castlingFrom = move.to - 2;
        board[castlingTo] = board[castlingFrom];
        board[castlingFrom] = null;
      }

      /* turn off castling */
      castling[us] = 0;
    }

    /* turn off castling if we move a rook */
    if (castling[us] != 0) {
      for (var i = 0, len = rooks[us]!.length; i < len; i++) {
        if (move.from == rooks[us]![i]['square'] && ((castling[us] & rooks[us]![i]['flag']) != 0)) {
          castling[us] ^= rooks[us]![i]['flag'];
          break;
        }
      }
    }

    /* turn off castling if we capture a rook */
    if (castling[them] != 0) {
      for (var i = 0, len = rooks[them]!.length; i < len; i++) {
        if (move.to == rooks[them]![i]['square'] && ((castling[them] & rooks[them]![i]['flag']) != 0)) {
          castling[them] ^= rooks[them]![i]['flag'];
          break;
        }
      }
    }

    /* if big pawn move, update the en passant square */
    var theirPawn = Piece(pawn, them);
    if ((move.flags & bitsBigPawn) != 0 && (theirPawn.eq(board[move.to - 1]) || theirPawn.eq(board[move.to + 1]))) {
      if (turn == black) {
        epSquare = move.to - 16;
      } else {
        epSquare = move.to + 16;
      }
    } else {
      epSquare = null;
    }

    /* reset the 50 move counter if a pawn is moved or a piece is captured */
    if (move.piece == pawn) {
      halfMoves = 0;
    } else if ((move.flags & (bitsCapture | bitsEpCapture)) != 0) {
      halfMoves = 0;
    } else {
      halfMoves++;
    }

    if (turn == black) {
      moveNumber++;
    }
    turn = swapColor(turn);

    // (ThreeCheck logic moved to subclass override)
  }

  /// Undoes a move and returns it, or null if move history is empty
  Move? undoMove() {
    if (history.isEmpty) {
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

    final us = turn;
    final them = swapColor(turn);

    board[move.from] = board[move.to];
    board[move.from]!.type = move.piece; // to undo any promotions
    board[move.to] = null;

    if ((move.flags & bitsCapture) != 0) {
      board[move.to] = Piece(move.captured!, them);
    } else if ((move.flags & bitsEpCapture) != 0) {
      int index;
      if (us == black) {
        index = move.to - 16;
      } else {
        index = move.to + 16;
      }
      board[index] = Piece(pawn, them);
    }

    if ((move.flags & (bitsKsideCastle | bitsQsideCastle)) != 0) {
      int castlingTo, castlingFrom;
      if ((move.flags & bitsKsideCastle) != 0) {
        castlingTo = move.to + 1;
        castlingFrom = move.to - 1;
      } else {
        castlingTo = move.to - 2;
        castlingFrom = move.to + 1;
      }

      board[castlingTo] = board[castlingFrom];
      board[castlingFrom] = null;
    }

    return move;
  }

  /* this function is used to uniquely identify ambiguous moves */
  String getDisambiguator(Move move) {
    var moves = generateMoves();

    var from = move.from;
    var to = move.to;
    var piece = move.piece;

    var ambiguities = 0;
    var sameRank = 0;
    var sameFile = 0;

    for (var i = 0, len = moves.length; i < len; i++) {
      var ambigFrom = moves[i].from;
      var ambigTo = moves[i].to;
      var ambigPiece = moves[i].piece;

      /* if a move of the same piece type ends on the same to square, we'll
       * need to add a disambiguator to the algebraic notation
       */
      if (piece == ambigPiece && from != ambigFrom && to == ambigTo) {
        ambiguities++;

        if (rank(from) == rank(ambigFrom)) {
          sameRank++;
        }

        if (file(from) == file(ambigFrom)) {
          sameFile++;
        }
      }
    }

    if (ambiguities > 0) {
      /* if there exists a similar moving piece on the same rank and file as
       * the move in question, use the square as the disambiguator
       */
      if (sameRank > 0 && sameFile > 0) {
        return algebraic(from);
      } /* if the moving piece rests on the same file, use the rank symbol as the
       * disambiguator
       */
      else if (sameFile > 0) {
        return algebraic(from)[1];
      } /* else use the file symbol */
      else {
        return algebraic(from)[0];
      }
    }

    return '';
  }

  /// Returns a String representation of the current position
  /// complete with ascii art
  String get ascii {
    var s = '   +------------------------+\n';
    for (var i = squaresA8; i <= squaresH1; i++) {
      /* display the rank */
      if (file(i) == 0) {
        s += ' ' + '87654321'[rank(i)] + ' |';
      }

      /* empty piece */
      if (board[i] == null) {
        s += ' . ';
      } else {
        var type = board[i]!.type;
        var color = board[i]!.color;
        var symbol = (color == white) ? type.toUpperCase() : type.toLowerCase();
        s += ' ' + symbol + ' ';
      }

      if (((i + 1) & 0x88) != 0) {
        s += '|\n';
        i += 8;
      }
    }
    s += '   +------------------------+\n';
    s += '     a  b  c  d  e  f  g  h\n';

    return s;
  }

  // Utility Functions
  static int rank(int i) {
    return i >> 4;
  }

  static int file(int i) {
    return i & 15;
  }

  static String algebraic(int i) {
    var f = file(i), r = rank(i);
    return 'abcdefgh'.substring(f, f + 1) + '87654321'.substring(r, r + 1);
  }

  static PlayerColor swapColor(PlayerColor c) {
    return c == white ? black : white;
  }

  static bool isDigit(String c) {
    return '0123456789'.contains(c);
  }

  /// pretty = external move object
  Map<String, dynamic> makePretty(Move uglyMove) {
    final map = <String, dynamic>{};
    map['san'] = moveToSan(uglyMove);
    map['to'] = uglyMove.toAlgebraic;
    map['from'] = uglyMove.fromAlgebraic;
    map['captured'] = uglyMove.captured;

    var flags = '';
    for (var flag in bits.keys) {
      if ((bits[flag]! & uglyMove.flags) != 0) {
        flags += moveFlags[flag]!;
      }
    }
    map['flags'] = flags;

    return map;
  }

  String trim(String str) {
    return str.replaceAll(RegExp(r'^\s+|\s+$'), '');
  }

  // debug utility
  int perft(int? depth) {
    var moves = generateMoves({'legal': false});
    var nodes = 0;
    var color = turn;

    for (var i = 0, len = moves.length; i < len; i++) {
      makeMove(moves[i]);
      if (!kingAttacked(color)) {
        if (depth! - 1 > 0) {
          var childNodes = perft(depth - 1);
          nodes += childNodes;
        } else {
          nodes++;
        }
      }
      undoMove();
    }

    return nodes;
  }

  //Public APIs

  ///  Returns a list of legals moves from the current position.
  ///  The function takes an optional parameter which controls the
  ///  single-square move generation and verbosity.
  ///
  ///  The piece, captured, and promotion fields contain the lowercase
  ///  representation of the applicable piece.
  ///
  ///  The flags field in verbose mode may contain one or more of the following values:
  ///
  ///  'n' - a non-capture
  ///  'b' - a pawn push of two squares
  ///  'e' - an en passant capture
  ///  'c' - a standard capture
  ///  'p' - a promotion
  ///  'k' - kingside castling
  ///  'q' - queenside castling
  ///  A flag of 'pc' would mean that a pawn captured a piece on the 8th rank and promoted.
  ///
  ///  If "asObjects" is set to true in the options Map, then it returns a List<Move>
  List moves([Map? options]) {
    /* The internal representation of a chess move is in 0x88 format, and
       * not meant to be human-readable.  The code below converts the 0x88
       * square coordinates to algebraic coordinates.  It also prunes an
       * unnecessary move keys resulting from a verbose call.
       */

    final uglyMoves = generateMoves(options);
    if (options != null && options.containsKey('asObjects') && options['asObjects'] == true) {
      return uglyMoves;
    }
    final moves = [];

    for (var i = 0, len = uglyMoves.length; i < len; i++) {
      /* does the user want a full move object (most likely not), or just
         * SAN
         */
      if (options != null && options.containsKey('verbose') && options['verbose'] == true) {
        moves.add(makePretty(uglyMoves[i]));
      } else {
        moves.add(moveToSan(uglyMoves[i]));
      }
    }

    return moves;
  }

  bool get isThreeCheckGameOver => false;

  bool get inDraw {
    return halfMoves >= 100 || inStalemate || insufficientMaterial || inThreefoldRepetition;
  }

  bool get gameOver {
    return inDraw || inCheckmate || isThreeCheckGameOver;
  }

  String get fen {
    return generateFen();
  }

  String get bfen {
    return generateBfen();
  }

  /// return the san string representation of each move in history. Each string corresponds to one move.
  List<String?> sanMoves() {
    /* pop all of history onto reversed_history */
    final reversedHistory = <Move?>[];
    while (history.isNotEmpty) {
      reversedHistory.add(undoMove());
    }

    final moves = <String?>[];
    var moveString = '';
    var pgnMoveNumber = 1;

    /* build the list of moves.  a move_string looks like: "3. e3 e6" */
    while (reversedHistory.isNotEmpty) {
      final move = reversedHistory.removeLast()!;

      /* if the position started with black to move, start PGN with 1. ... */
      if (pgnMoveNumber == 1 && move.color == black) {
        moveString = '1. ...';
        pgnMoveNumber++;
      } else if (move.color == white) {
        /* store the previous generated move_string if we have one */
        if (moveString.isNotEmpty) {
          moves.add(moveString);
        }
        moveString = pgnMoveNumber.toString() + '.';
        pgnMoveNumber++;
      }

      moveString = moveString + ' ' + moveToSan(move);
      makeMove(move);
    }

    /* are there any other leftover moves? */
    if (moveString.isNotEmpty) {
      moves.add(moveString);
    }

    /* is there a result? */
    if (header['Result'] != null) {
      moves.add(header['Result']);
    }

    return moves;
  }

  /// Return the PGN representation of the game thus far
  String pgn([Map? options]) {
    /* using the specification from http://www.chessclub.com/help/PGN-spec
       * example for html usage: .pgn({ max_width: 72, newline_char: "<br />" })
       */
    final newline = (options != null && options.containsKey('newline_char') && options['newline_char'] != null)
        ? options['newline_char']
        : '\n';
    final maxWidth = (options != null && options.containsKey('max_width') && options['max_width'] != null)
        ? options['max_width']
        : 0;
    final result = [];
    var headerExists = false;

    /* add the PGN header headerrmation */
    for (var i in header.keys) {
      /* order of enumerated properties in header object is not
       * guaranteed, see ECMA-262 spec (section 12.6.4)
       */
      result.add('[' + i.toString() + ' "' + header[i].toString() + '"]' + newline);
      headerExists = true;
    }

    if (headerExists && (history.isNotEmpty)) {
      result.add(newline);
    }

    final moves = sanMoves();

    if (maxWidth == 0) {
      return result.join('') + moves.join(' ');
    }

    /* wrap the PGN output at max_width */
    var currentWidth = 0;
    for (var i = 0; i < moves.length; i++) {
      /* if the current move will push past max_width */
      if (currentWidth + moves[i]!.length > maxWidth && i != 0) {
        /* don't end the line with whitespace */
        if (result[result.length - 1] == ' ') {
          result.removeLast();
        }

        result.add(newline);
        currentWidth = 0;
      } else if (i != 0) {
        result.add(' ');
        currentWidth++;
      }
      result.add(moves[i]);
      currentWidth += moves[i]!.length;
    }

    return result.join('');
  }

  /// Load the moves of a game stored in Portable Game Notation.
  /// [options] is an optional parameter that contains a 'newline_char'
  /// which is a string representation of a RegExp (and should not be pre-escaped)
  /// and defaults to '\r?\n').
  /// Returns [true] if the PGN was parsed successfully, otherwise [false].
  bool loadPgn(String? pgn, [Map? options]) {
    String mask(str) {
      return str.replaceAll(RegExp(r'\\'), '\\');
    }

    /* convert a move from Standard Algebraic Notation (SAN) to 0x88
     * coordinates
     */
    Move? moveFromSan(move) {
      final moves = generateMoves();
      final cleanMove = move.replaceAll(RegExp(r'[+#?!=]+$'), '');
      for (var i = 0, len = moves.length; i < len; i++) {
        /* strip off any trailing move decorations: e.g Nf3+?! */
        if (cleanMove == moveToSan(moves[i]).replaceAll(RegExp(r'[+#?!=]+$'), '')) {
          return moves[i];
        }
        
        /* Check for Long Algebraic Notation (LAN) / UCI notation e.g. d2d4, Ng8f6 */
        final lan = moves[i].fromAlgebraic + moves[i].toAlgebraic;
        final pieceLan = (moves[i].piece == pawn ? '' : moves[i].piece.toUpperCase()) + lan;
        final promo = moves[i].promotion != null ? moves[i].promotion!.name : '';
        final promoSan = moves[i].promotion != null ? '=${moves[i].promotion!.name.toUpperCase()}' : '';
        
        if (cleanMove == lan + promo ||
            cleanMove == lan + promo.toLowerCase() ||
            cleanMove == lan + promoSan ||
            cleanMove == pieceLan + promo ||
            cleanMove == pieceLan + promo.toLowerCase() ||
            cleanMove == pieceLan + promoSan) {
          return moves[i];
        }
      }
      return null;
    }

    Move? getMoveObj(move) {
      return moveFromSan(trim(move));
    }

    Map<String, String> parsePgnHeader(header, [Map? options]) {
      final newlineChar = (options != null && options.containsKey('newline_char')) ? options['newline_char'] : '\r?\n';
      final headerObj = <String, String>{};
      final headers = header.split(RegExp(newlineChar));
      var key = '';
      var value = '';

      for (var i = 0; i < headers.length; i++) {
        var keyMatch = RegExp(r'^\[([A-Z][A-Za-z]*)\s.*\]$');
        var temp = keyMatch.firstMatch(headers[i]);
        if (temp != null) {
          key = temp[1]!;
        }
        //print(key);
        var valueMatch = RegExp(r'^\[[A-Za-z]+\s"(.*)"\]$');
        temp = valueMatch.firstMatch(headers[i]);
        if (temp != null) {
          value = temp[1]!;
        }
        //print(value);
        if (trim(key).isNotEmpty) {
          headerObj[key] = value;
        }
      }

      return headerObj;
    }

    final newlineChar = (options != null && options.containsKey('newline_char')) ? options['newline_char'] : '\r?\n';
    //var regex = new RegExp(r'^(\[.*\]).*' + r'1\.'); //+ r"1\."); //+ mask(newline_char));

    final indexOfMoveStart = pgn!.indexOf(RegExp(newlineChar + r'1\.'));

    /* get header part of the PGN file */
    String? headerString;
    if (indexOfMoveStart != -1) {
      headerString = pgn.substring(0, indexOfMoveStart).trim();
    }

    /* no info part given, begins with moves */
    if (headerString == null || headerString[0] != '[') {
      headerString = '';
    }

    reset();

    /* parse PGN header */
    final headers = parsePgnHeader(headerString, options);
    for (var key in headers.keys) {
      setHeader([key, headers[key]]);
    }

    /* delete header to get the moves */
    var ms = pgn.replaceAll(headerString, '').replaceAll(RegExp(mask(newlineChar)), ' ');

    /* delete comments */
    ms = ms.replaceAll(RegExp(r'({[^}]+\})+?'), '');

    /* delete move numbers */
    ms = ms.replaceAll(RegExp(r'\d+\.'), '');

    /* trim and get array of moves */
    var moves = trim(ms).split(RegExp(r'\s+'));

    /* delete empty entries */
    moves = moves.join(',').replaceAll(RegExp(r',,+'), ',').split(',');

    for (var halfMove = 0; halfMove < moves.length - 1; halfMove++) {
      var move = getMoveObj(moves[halfMove]);

      /* move not possible! (don't clear the board to examine to show the
       * latest valid position)
       */
      if (move == null) {
        return false;
      } else {
        makeMove(move);
      }
    }

    /* examine last move */
    var move = moves[moves.length - 1];
    if (possibleResults.contains(move)) {
      if (!header.containsKey('Result')) {
        setHeader(['Result', move]);
      }
    } else {
      final moveObj = getMoveObj(move);
      if (moveObj == null) {
        return false;
      } else {
        makeMove(moveObj);
      }
    }
    return true;
  }

  /// The move function can be called with in the following parameters:
  /// .move('Nxb7')      <- where 'move' is a case-sensitive SAN string
  /// .move({ from: 'h7', <- where the 'move' is a move object (additional
  ///      to :'h8',      fields are ignored)
  ///      promotion: 'q',
  ///      })
  /// or it can be called with a Move object
  /// It returns true if the move was made, or false if it could not be.
  bool move(move) {
    Move? moveObj;
    final moves = generateMoves();

    if (move is String) {
      /* convert the move string to a move object */
      for (var i = 0; i < moves.length; i++) {
        if (move == moveToSan(moves[i])) {
          moveObj = moves[i];
          break;
        }
      }

      for (var i = 0; i < moves.length; i++) {
        String n = normalizeMoveString(moveToSan(moves[i]));
        if (move == n) {
          moveObj = moves[i];
          break;
        }
      }
      // try again with ambiguated move
      move = ambiguate(move);
      for (var i = 0; i < moves.length; i++) {
        String n = normalizeMoveString(moveToSan(moves[i]));
        if (move == n) {
          moveObj = moves[i];
          break;
        }
      }
    } else if (move is Map) {
      /* convert the pretty move object to an ugly move object */
      for (var i = 0; i < moves.length; i++) {
        if (move['from'] == moves[i].fromAlgebraic &&
            move['to'] == moves[i].toAlgebraic &&
            (moves[i].promotion == null || move['promotion'] == moves[i].promotion!.name)) {
          moveObj = moves[i];
          break;
        }
      }
    } else if (move is Move) {
      moveObj = move;
    }

    /* failed to find move */
    if (moveObj == null) {
      return false;
    }

    // need to make a copy of move because we can't generate SAN after the move is made
    makeMove(moveObj);

    return true;
  }

  String ambiguate(String s) {
    var r = RegExp(r"^[NRQ][a-h1-8][a-h][1-8]$");
    if (r.hasMatch(s)) {
      return s.substring(0, 1) + s.substring(2);
    }
    return s;
  }

  String normalizeMoveString(String s) {
    return s.replaceAll(RegExp(r"[x+=#]"), "");
  }

  /// Takeback the last half-move, returning a move Map if successful, otherwise null.
  Map<String, dynamic>? undo() {
    final move = undoMove();
    return (move != null) ? makePretty(move) : null;
  }

  /// Returns the color of the square ('light' or 'dark'), or null if [square] is invalid
  String? squareColor(square) {
    if (squares.containsKey(square)) {
      final sq_0x88 = squares[square];
      return ((rank(sq_0x88) + file(sq_0x88)) % 2 == 0) ? 'light' : 'dark';
    }

    return null;
  }

  List getHistory([Map? options]) {
    final reversedHistory = <Move?>[];
    final moveHistory = [];
    final verbose = (options != null && options.containsKey('verbose') && options['verbose'] == true);

    while (history.isNotEmpty) {
      reversedHistory.add(undoMove());
    }

    while (reversedHistory.isNotEmpty) {
      final move = reversedHistory.removeLast()!;
      if (verbose) {
        moveHistory.add(makePretty(move));
      } else {
        moveHistory.add(moveToSan(move));
      }
      makeMove(move);
    }

    return moveHistory;
  }
}

class Piece {
  PieceType type;
  final PlayerColor color;
  Piece(this.type, this.color);

  bool eq(Piece? piece) {
    return piece != null && type == piece.type && color == piece.color;
  }
}

class PieceType {
  final int shift;
  final String name;
  const PieceType._internal(this.shift, this.name);

  static const PieceType pawn = PieceType._internal(0, 'p');
  static const PieceType knight = PieceType._internal(1, 'n');
  static const PieceType bishop = PieceType._internal(2, 'b');
  static const PieceType rook = PieceType._internal(3, 'r');
  static const PieceType queen = PieceType._internal(4, 'q');
  static const PieceType king = PieceType._internal(5, 'k');

  @override
  String toString() => name;
  String toLowerCase() => name;
  String toUpperCase() => name.toUpperCase();
}

enum PlayerColor { white, black }

class ColorMap<T> {
  T _white;
  T _black;
  ColorMap(T value)
      : _white = value,
        _black = value;
  ColorMap.clone(ColorMap other)
      : _white = other._white,
        _black = other._black;

  T operator [](PlayerColor color) {
    return (color == white) ? _white : _black;
  }

  void operator []=(PlayerColor color, T value) {
    if (color == white) {
      _white = value;
    } else {
      _black = value;
    }
  }
}

class Move {
  final PlayerColor color;
  final int from;
  final int to;
  final int flags;
  final PieceType piece;
  final PieceType? captured;
  final PieceType? promotion;
  const Move(this.color, this.from, this.to, this.flags, this.piece, this.captured, this.promotion);

  String get fromAlgebraic {
    return Chess.algebraic(from);
  }

  String get toAlgebraic {
    return Chess.algebraic(to);
  }
}

class GameState {
  final Move move;
  final ColorMap<int> kings;
  final PlayerColor turn;
  final ColorMap<int> castling;
  final int? epSquare;
  final int halfMoves;
  final int moveNumber;
  final ColorMap<int> checksCount;
  const GameState(this.move, this.kings, this.turn, this.castling, this.epSquare, this.halfMoves, this.moveNumber, this.checksCount);
}

