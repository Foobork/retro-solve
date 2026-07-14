import 'dart:math';

import 'package:chess_vectors_flutter/chess_vectors_flutter.dart';
import 'package:flutter/material.dart';

import '../chess/chess.dart';
import 'board_arrow.dart';
import 'chess_board_controller.dart';

/// Enum which stores board types
enum BoardColor {
  brown,
  darkBrown,
  orange,
  green,
}

extension BoardColorColors on BoardColor {
  Color get lightSquare {
    switch (this) {
      case BoardColor.brown:
        return const Color(0xFFF0D9B5);
      case BoardColor.darkBrown:
        return const Color(0xFFE8D3B9);
      case BoardColor.orange:
        return const Color(0xFFFFDFB0);
      case BoardColor.green:
        return const Color(0xFFE2E4C0);
    }
  }

  Color get darkSquare {
    switch (this) {
      case BoardColor.brown:
        return const Color(0xFFB58863);
      case BoardColor.darkBrown:
        return const Color(0xFF8B5A2B);
      case BoardColor.orange:
        return const Color(0xFFD2691E);
      case BoardColor.green:
        return const Color(0xFF578A34);
    }
  }
}


const _files = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];

class ChessBoard extends StatefulWidget {
  /// An instance of [ChessBoardController] which holds the game and allows
  /// manipulating the board programmatically.
  final ChessBoardController controller;

  /// Size of chessboard
  final double? size;

  /// A boolean which checks if the user should be allowed to make moves
  final bool enableUserMoves;

  /// The color type of the board
  final BoardColor boardColor;

  final PlayerColor boardOrientation;

  final VoidCallback? onMove;

  final List<BoardArrow> arrows;

  const ChessBoard({
    Key? key,
    required this.controller,
    this.size,
    this.enableUserMoves = true,
    this.boardColor = BoardColor.brown,
    this.boardOrientation = white,
    this.onMove,
    this.arrows = const [],
  }) : super(key: key);

  @override
  State<ChessBoard> createState() => _ChessBoardState();
}

class _ChessBoardState extends State<ChessBoard> {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Chess>(
      valueListenable: widget.controller,
      builder: (context, game, _) {
        final boardWidget = Stack(
          children: [
            AspectRatio(
              aspectRatio: 1.0,
              child: GridView.builder(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 8),
                itemBuilder: (context, index) {
                  var row = index ~/ 8;
                  var column = index % 8;
                  var boardRank = widget.boardOrientation == black ? '${row + 1}' : '${(7 - row) + 1}';
                  var boardFile = widget.boardOrientation == white ? _files[column] : _files[7 - column];

                  var squareName = '$boardFile$boardRank';
                  var pieceOnSquare = game.get(squareName);

                  var piece = BoardPiece(
                    squareName: squareName,
                    game: game,
                  );

                  var draggable = game.get(squareName) != null
                      ? (widget.enableUserMoves
                          ? Draggable<PieceMoveData>(
                              child: piece,
                              feedback: Material(
                                color: Colors.transparent,
                                child: piece,
                              ),
                              childWhenDragging: const SizedBox(),
                              data: PieceMoveData(
                                squareName: squareName,
                                pieceType: pieceOnSquare?.type.toUpperCase() ?? 'P',
                                pieceColor: pieceOnSquare?.color ?? white,
                              ),
                            )
                          : piece)
                      : Container();

                  var dragTarget = DragTarget<PieceMoveData>(builder: (context, list, _) {
                    return draggable;
                  }, onWillAcceptWithDetails: (pieceMoveData) {
                    return widget.enableUserMoves ? true : false;
                  }, onAcceptWithDetails: (DragTargetDetails<PieceMoveData> dragTargetDetails) async {
                    PieceMoveData pieceMoveData = dragTargetDetails.data;
                    // A way to check if move occurred.
                    PlayerColor moveColor = game.turn;

                    if (pieceMoveData.pieceType == "P" &&
                        !pieceMoveData.squareName.startsWith('@') &&
                        ((pieceMoveData.squareName[1] == "7" &&
                                squareName[1] == "8" &&
                                pieceMoveData.pieceColor == white) ||
                            (pieceMoveData.squareName[1] == "2" &&
                                squareName[1] == "1" &&
                                pieceMoveData.pieceColor == black))) {
                      var val = await _promotionDialog(context);

                      if (val != null) {
                        widget.controller.makeMoveWithPromotion(
                          from: pieceMoveData.squareName,
                          to: squareName,
                          pieceToPromoteTo: val,
                        );
                      } else {
                        return;
                      }
                    } else {
                      widget.controller.makeMove(
                        from: pieceMoveData.squareName,
                        to: squareName,
                      );
                    }
                    if (game.turn != moveColor) {
                      widget.onMove?.call();
                    }
                  });

                  final isLightSquare = (row + column) % 2 == 0;
                  final squareColor = isLightSquare ? widget.boardColor.lightSquare : widget.boardColor.darkSquare;

                  return Container(
                    color: squareColor,
                    child: dragTarget,
                  );
                },
                itemCount: 64,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
              ),
            ),
            if (widget.arrows.isNotEmpty)
              IgnorePointer(
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: CustomPaint(
                    child: Container(),
                    painter: _ArrowPainter(widget.arrows, widget.boardOrientation),
                  ),
                ),
              ),
          ],
        );

        if (game is CrazyhouseChess) {
          final topColor = widget.boardOrientation == white ? black : white;
          final bottomColor = widget.boardOrientation == white ? white : black;

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildPocket(game, topColor),
              const SizedBox(height: 4.0),
              Expanded(child: boardWidget),
              const SizedBox(height: 4.0),
              _buildPocket(game, bottomColor),
            ],
          );
        } else {
          return SizedBox(
            width: widget.size,
            height: widget.size,
            child: boardWidget,
          );
        }
      },
    );
  }

  Widget _buildPocket(CrazyhouseChess game, PlayerColor color) {
    final pocket = game.pockets[color]!;
    final types = [PieceType.queen, PieceType.rook, PieceType.bishop, PieceType.knight, PieceType.pawn];

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      color: Colors.grey.shade100,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: types.map((type) {
          final count = pocket[type] ?? 0;
          final hasPieces = count > 0;
          final letter = type.name.toUpperCase();
          final dropCode = '$letter@';

          Widget pieceWidget = SizedBox(
            width: 40,
            height: 40,
            child: Opacity(
              opacity: hasPieces ? 1.0 : 0.25,
              child: _getPieceVector(type, color),
            ),
          );

          Widget pieceWithBadge = Stack(
            clipBehavior: Clip.none,
            children: [
              pieceWidget,
              if (hasPieces)
                Positioned(
                  right: -4,
                  bottom: -4,
                  child: Container(
                    padding: const EdgeInsets.all(2.0),
                    decoration: const BoxDecoration(
                      color: Colors.deepPurple,
                      shape: BoxShape.circle,
                    ),
                    constraints: const BoxConstraints(
                      minWidth: 16,
                      minHeight: 16,
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          );

          if (hasPieces && widget.enableUserMoves) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: Draggable<PieceMoveData>(
                feedback: Material(
                  color: Colors.transparent,
                  child: SizedBox(
                    width: 50,
                    height: 50,
                    child: _getPieceVector(type, color),
                  ),
                ),
                childWhenDragging: Opacity(
                  opacity: 0.3,
                  child: pieceWithBadge,
                ),
                data: PieceMoveData(
                  squareName: dropCode,
                  pieceType: letter,
                  pieceColor: color,
                ),
                child: pieceWithBadge,
              ),
            );
          } else {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8.0),
              child: pieceWithBadge,
            );
          }
        }).toList(),
      ),
    );
  }

  Widget _getPieceVector(PieceType type, PlayerColor color) {
    if (color == white) {
      switch (type) {
        case PieceType.pawn: return WhitePawn();
        case PieceType.knight: return WhiteKnight();
        case PieceType.bishop: return WhiteBishop();
        case PieceType.rook: return WhiteRook();
        case PieceType.queen: return WhiteQueen();
        case PieceType.king: return WhiteKing();
      }
    } else {
      switch (type) {
        case PieceType.pawn: return BlackPawn();
        case PieceType.knight: return BlackKnight();
        case PieceType.bishop: return BlackBishop();
        case PieceType.rook: return BlackRook();
        case PieceType.queen: return BlackQueen();
        case PieceType.king: return BlackKing();
      }
    }
    return const SizedBox();
  }

  /// Show dialog when pawn reaches last square
  Future<String?> _promotionDialog(BuildContext context) async {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Choose promotion'),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: <Widget>[
              InkWell(
                child: WhiteQueen(),
                onTap: () {
                  Navigator.of(context).pop("q");
                },
              ),
              InkWell(
                child: WhiteRook(),
                onTap: () {
                  Navigator.of(context).pop("r");
                },
              ),
              InkWell(
                child: WhiteBishop(),
                onTap: () {
                  Navigator.of(context).pop("b");
                },
              ),
              InkWell(
                child: WhiteKnight(),
                onTap: () {
                  Navigator.of(context).pop("n");
                },
              ),
            ],
          ),
        );
      },
    ).then((value) {
      return value;
    });
  }
}

class BoardPiece extends StatelessWidget {
  final String squareName;
  final Chess game;

  const BoardPiece({
    Key? key,
    required this.squareName,
    required this.game,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    late Widget imageToDisplay;
    var square = game.get(squareName);

    if (game.get(squareName) == null) {
      return Container();
    }

    String piece = (square?.color == white ? 'W' : 'B') + (square?.type.toUpperCase() ?? 'P');

    switch (piece) {
      case "WP":
        imageToDisplay = WhitePawn();
        break;
      case "WR":
        imageToDisplay = WhiteRook();
        break;
      case "WN":
        imageToDisplay = WhiteKnight();
        break;
      case "WB":
        imageToDisplay = WhiteBishop();
        break;
      case "WQ":
        imageToDisplay = WhiteQueen();
        break;
      case "WK":
        imageToDisplay = WhiteKing();
        break;
      case "BP":
        imageToDisplay = BlackPawn();
        break;
      case "BR":
        imageToDisplay = BlackRook();
        break;
      case "BN":
        imageToDisplay = BlackKnight();
        break;
      case "BB":
        imageToDisplay = BlackBishop();
        break;
      case "BQ":
        imageToDisplay = BlackQueen();
        break;
      case "BK":
        imageToDisplay = BlackKing();
        break;
      default:
        imageToDisplay = WhitePawn();
    }

    if (game.isThreeCheck && square != null && square.type == PieceType.king) {
      final opponentColor = square.color == white ? black : white;
      final remainingChecks = game.checksCount[opponentColor];
      
      final kingImage = imageToDisplay;
      imageToDisplay = LayoutBuilder(
        builder: (context, constraints) {
          final double squareSize = constraints.hasBoundedWidth ? constraints.maxWidth : 50.0;
          final badgeSize = (squareSize * 0.50).clamp(16.0, 48.0);
          final fontSize = badgeSize * 0.55;
          final borderWidth = (badgeSize * 0.08).clamp(1.0, 3.0);

          return Stack(
            fit: StackFit.passthrough,
            clipBehavior: Clip.none,
            children: [
              kingImage,
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  padding: EdgeInsets.all(badgeSize * 0.15),
                  decoration: BoxDecoration(
                    color: _getBadgeColor(remainingChecks),
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: borderWidth),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 2,
                        offset: Offset(0, 1),
                      ),
                    ],
                  ),
                  width: badgeSize,
                  height: badgeSize,
                  child: Center(
                    child: Text(
                      '$remainingChecks',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: fontSize,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      );
    }

    return imageToDisplay;
  }

  Color _getBadgeColor(int remaining) {
    switch (remaining) {
      case 3:
        return Colors.green.shade600;
      case 2:
        return Colors.amber.shade700;
      case 1:
        return Colors.red.shade700;
      default:
        return Colors.grey.shade600;
    }
  }
}

class PieceMoveData {
  final String squareName;
  final String pieceType;
  final PlayerColor pieceColor;

  PieceMoveData({
    required this.squareName,
    required this.pieceType,
    required this.pieceColor,
  });
}

class _ArrowPainter extends CustomPainter {
  List<BoardArrow> arrows;
  PlayerColor boardOrientation;

  _ArrowPainter(this.arrows, this.boardOrientation);

  @override
  void paint(Canvas canvas, Size size) {
    var blockSize = size.width / 8;
    var halfBlockSize = size.width / 16;

    for (var arrow in arrows) {
      var startFile = _files.indexOf(arrow.from[0]);
      var startRank = int.parse(arrow.from[1]) - 1;
      var endFile = _files.indexOf(arrow.to[0]);
      var endRank = int.parse(arrow.to[1]) - 1;

      int effectiveRowStart = 0;
      int effectiveColumnStart = 0;
      int effectiveRowEnd = 0;
      int effectiveColumnEnd = 0;

      if (boardOrientation == PlayerColor.black) {
        effectiveColumnStart = 7 - startFile;
        effectiveColumnEnd = 7 - endFile;
        effectiveRowStart = startRank;
        effectiveRowEnd = endRank;
      } else {
        effectiveColumnStart = startFile;
        effectiveColumnEnd = endFile;
        effectiveRowStart = 7 - startRank;
        effectiveRowEnd = 7 - endRank;
      }

      var startOffset = Offset(((effectiveColumnStart + 1) * blockSize) - halfBlockSize,
          ((effectiveRowStart + 1) * blockSize) - halfBlockSize);
      var endOffset = Offset(
          ((effectiveColumnEnd + 1) * blockSize) - halfBlockSize, ((effectiveRowEnd + 1) * blockSize) - halfBlockSize);

      var yDist = 0.8 * (endOffset.dy - startOffset.dy);
      var xDist = 0.8 * (endOffset.dx - startOffset.dx);

      var paint = Paint()
        ..strokeWidth = halfBlockSize * 0.8
        ..color = arrow.color;

      canvas.drawLine(startOffset, Offset(startOffset.dx + xDist, startOffset.dy + yDist), paint);

      var slope = (endOffset.dy - startOffset.dy) / (endOffset.dx - startOffset.dx);

      var newLineSlope = -1 / slope;

      var points = _getNewPoints(Offset(startOffset.dx + xDist, startOffset.dy + yDist), newLineSlope, halfBlockSize);
      var newPoint1 = points[0];
      var newPoint2 = points[1];

      var path = Path();

      path.moveTo(endOffset.dx, endOffset.dy);
      path.lineTo(newPoint1.dx, newPoint1.dy);
      path.lineTo(newPoint2.dx, newPoint2.dy);
      path.close();

      canvas.drawPath(path, paint);
    }
  }

  List<Offset> _getNewPoints(Offset start, double slope, double length) {
    if (slope == double.infinity || slope == double.negativeInfinity) {
      return [Offset(start.dx, start.dy + length), Offset(start.dx, start.dy - length)];
    }

    return [
      Offset(
          start.dx + (length / sqrt(1 + (slope * slope))), start.dy + ((length * slope) / sqrt(1 + (slope * slope)))),
      Offset(
          start.dx - (length / sqrt(1 + (slope * slope))), start.dy - ((length * slope) / sqrt(1 + (slope * slope)))),
    ];
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) {
    return arrows != oldDelegate.arrows;
  }
}
