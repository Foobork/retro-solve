// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

typedef _TbInitNative = Int32 Function();
typedef _TbInitDart = int Function();

typedef _TbAddPathNative = Int32 Function(Pointer<Uint8> path, Size pathLen);
typedef _TbAddPathDart = int Function(Pointer<Uint8> path, int pathLen);

typedef _TbProbeDtwNative = Int32 Function(
  Pointer<Int32> whiteSquares,
  Pointer<Int32> whitePieces,
  Size numWhitePieces,
  Pointer<Int32> blackSquares,
  Pointer<Int32> blackPieces,
  Size numBlackPieces,
  Int32 sideToMove,
  Int32 epSquare,
  Pointer<Int32> dtw,
);
typedef _TbProbeDtwDart = int Function(
  Pointer<Int32> whiteSquares,
  Pointer<Int32> whitePieces,
  int numWhitePieces,
  Pointer<Int32> blackSquares,
  Pointer<Int32> blackPieces,
  int numBlackPieces,
  int sideToMove,
  int epSquare,
  Pointer<Int32> dtw,
);

typedef _MallocNative = Pointer<Void> Function(Size size);
typedef _MallocDart = Pointer<Void> Function(int size);
typedef _FreeNative = Void Function(Pointer<Void> ptr);
typedef _FreeDart = void Function(Pointer<Void> ptr);

class AntichessTbResult {
  /// 1 = White win, 0 = Draw, -1 = Black win
  final int whitePerspectiveResult;

  /// Distance to win in plies (>= 0), or null for Draw
  final int? dtw;

  /// True if cursed by the 50-move rule (dtz > 100)
  final bool dtzOver100;

  const AntichessTbResult({
    required this.whitePerspectiveResult,
    required this.dtw,
    required this.dtzOver100,
  });
}

class AntichessTbProber {
  late final DynamicLibrary _lib;
  late final DynamicLibrary _crt;
  late final _TbInitDart _tbInit;
  late final _TbAddPathDart _tbAddPath;
  late final _TbProbeDtwDart _tbProbeDtw;
  late final _MallocDart _malloc;
  late final _FreeDart _free;

  late final Pointer<Int32> _wSq;
  late final Pointer<Int32> _wPc;
  late final Pointer<Int32> _bSq;
  late final Pointer<Int32> _bPc;
  late final Pointer<Int32> _dtwOut;

  bool _disposed = false;

  AntichessTbProber({
    String dllPath = 'data/tablebases/antichess/antichess_tb_api.dll',
    String tbDir = 'data/tablebases/antichess',
  }) {
    final dllFile = File(dllPath).absolute;
    if (!dllFile.existsSync()) {
      throw StateError('antichess_tb_api.dll not found at ${dllFile.path}');
    }
    _lib = DynamicLibrary.open(dllFile.path);
    _crt = DynamicLibrary.open('ucrtbase.dll');

    _tbInit = _lib.lookupFunction<_TbInitNative, _TbInitDart>(
      'antichess_tb_init',
    );
    _tbAddPath = _lib.lookupFunction<_TbAddPathNative, _TbAddPathDart>(
      'antichess_tb_add_path',
    );
    _tbProbeDtw = _lib.lookupFunction<_TbProbeDtwNative, _TbProbeDtwDart>(
      'antichess_tb_probe_dtw',
    );
    _malloc = _crt.lookupFunction<_MallocNative, _MallocDart>('malloc');
    _free = _crt.lookupFunction<_FreeNative, _FreeDart>('free');

    _wSq = _malloc(64 * sizeOf<Int32>()).cast<Int32>();
    _wPc = _malloc(64 * sizeOf<Int32>()).cast<Int32>();
    _bSq = _malloc(64 * sizeOf<Int32>()).cast<Int32>();
    _bPc = _malloc(64 * sizeOf<Int32>()).cast<Int32>();
    _dtwOut = _malloc(sizeOf<Int32>()).cast<Int32>();

    final initRes = _tbInit();
    if (initRes != 0) {
      throw StateError('antichess_tb_init() failed with code $initRes');
    }

    final absTbDir = Directory(tbDir).absolute.path;
    final pathBytes = utf8.encode(absTbDir);
    final pathPtr = _malloc(pathBytes.length + 1).cast<Uint8>();
    for (int i = 0; i < pathBytes.length; i++) {
      (pathPtr + i).value = pathBytes[i];
    }
    (pathPtr + pathBytes.length).value = 0;

    final addRes = _tbAddPath(pathPtr, pathBytes.length);
    _free(pathPtr.cast<Void>());
    if (addRes != 0) {
      print(
        'Warning: antichess_tb_add_path($absTbDir) returned $addRes (missing ${-addRes} of 714 files)',
      );
    }
  }

  static int _pieceCharToType(int codeUnit) {
    switch (codeUnit | 0x20) {
      case 0x70: // 'p'
        return 1;
      case 0x6e: // 'n'
        return 2;
      case 0x62: // 'b'
        return 3;
      case 0x72: // 'r'
        return 4;
      case 0x71: // 'q'
        return 5;
      case 0x6b: // 'k'
        return 6;
      default:
        return 0;
    }
  }

  /// Probes a BFEN or FEN string (must have 2..4 total pieces, >= 1 per side).
  /// Returns null if the position does not have 2..4 pieces or on error.
  AntichessTbResult? probeBfen(String bfen) {
    if (_disposed) {
      throw StateError('AntichessTbProber is already disposed');
    }

    final parts = bfen.split(' ');
    if (parts.length < 2) return null;

    final boardStr = parts[0];
    final stm = parts[1] == 'b' ? 1 : 0;
    int epSq = -1;
    if (parts.length >= 4 && parts[3] != '-' && parts[3].length == 2) {
      final f = parts[3].codeUnitAt(0) - 0x61; // 'a'
      final r = parts[3].codeUnitAt(1) - 0x31; // '1'
      if (f >= 0 && f < 8 && r >= 0 && r < 8) {
        epSq = r * 8 + f;
      }
    }

    int numW = 0;
    int numB = 0;
    int rank = 7;
    int file = 0;

    for (int i = 0; i < boardStr.length; i++) {
      final c = boardStr.codeUnitAt(i);
      if (c == 0x2f) {
        // '/'
        rank--;
        file = 0;
      } else if (c >= 0x31 && c <= 0x38) {
        // '1'..'8'
        file += c - 0x30;
      } else {
        final pt = _pieceCharToType(c);
        if (pt == 0) return null;
        final sq = rank * 8 + file;
        if (c >= 0x41 && c <= 0x5a) {
          // Uppercase = White
          (_wSq + numW).value = sq;
          (_wPc + numW).value = pt;
          numW++;
        } else {
          // Lowercase = Black
          (_bSq + numB).value = sq;
          (_bPc + numB).value = pt;
          numB++;
        }
        file++;
      }
    }

    if (numW < 1 || numB < 1 || (numW + numB) > 4) {
      return null;
    }

    _dtwOut.value = 0;
    final code = _tbProbeDtw(
      _wSq,
      _wPc,
      numW,
      _bSq,
      _bPc,
      numB,
      stm,
      epSq,
      _dtwOut,
    );

    if (code < 0) {
      return null;
    }
    if (code == 2) {
      return const AntichessTbResult(
        whitePerspectiveResult: 0,
        dtw: null,
        dtzOver100: false,
      );
    }

    final rawDtw = _dtwOut.value;
    final stmWins = rawDtw >= 0;
    final whiteWins = (stm == 0) ? stmWins : !stmWins;

    return AntichessTbResult(
      whitePerspectiveResult: whiteWins ? 1 : -1,
      dtw: rawDtw.abs(),
      dtzOver100: code == 1,
    );
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _free(_wSq.cast<Void>());
    _free(_wPc.cast<Void>());
    _free(_bSq.cast<Void>());
    _free(_bPc.cast<Void>());
    _free(_dtwOut.cast<Void>());
  }
}
