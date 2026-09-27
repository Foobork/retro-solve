import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';

String decodeMove(int mv) {
  if (mv == 0xfedc || mv == 0x0edc) return 'NULL';
  if ((mv >> 12) > 8 || (mv >> 12) == 7) {
    mv ^= 0xf000;
  }
  final fr = (mv >> 6) & 0x3f;
  final to = mv & 0x3f;
  final promIdx = (mv >> 12) & 0x7;
  const promChars = '01nbrqk7';

  final fromFile = String.fromCharCode('a'.codeUnitAt(0) + (fr & 7));
  final fromRank = (1 + (fr >> 3)).toString();
  final toFile = String.fromCharCode('a'.codeUnitAt(0) + (to & 7));
  final toRank = (1 + (to >> 3)).toString();

  var res = '$fromFile$fromRank$toFile$toRank';
  if ((mv & (7 << 12)) != 0 && promIdx < promChars.length) {
    res += promChars[promIdx];
  }
  return res;
}

class _TestNode {
  final int w;
  final int d;
  final String mv;

  const _TestNode(this.w, this.d, this.mv);
}

void main() {
  test('Nf3_17_blunders.proof conforms to Watkins proof tree binary specification', () async {
    const proofPath = 'data/Nf3_17_blunders.proof';
    final file = File(proofPath);
    expect(file.existsSync(), isTrue);

    final raf = await file.open(mode: FileMode.read);
    final header6 = await raf.read(6);
    final byteData = ByteData.sublistView(header6);
    final rawData = byteData.getUint32(0, Endian.little);
    final prologLen = byteData.getUint16(4, Endian.little);

    final nodeCount = rawData & 0x3fffffff;
    final hasChildren = (rawData & (1 << 30)) != 0;

    expect(nodeCount, equals(967));
    expect(hasChildren, isTrue);
    expect(prologLen, equals(1));

    // Read prolog move
    final prologBytes = await raf.read(2);
    final prologMv = ByteData.sublistView(prologBytes).getUint16(0, Endian.little);
    final prologUci = decodeMove(prologMv);
    expect(prologUci, equals('g1f3'));

    // Parity: odd prolog length means White played last -> White wins
    final provesWhiteWin = prologLen % 2 != 0;
    expect(provesWhiteWin, isTrue);

    final headerBytes = 6 + 2 * prologLen;

    Future<_TestNode> readNode(int u) async {
      await raf.setPosition(headerBytes + (u - 1) * 6);
      final bytes = await raf.read(6);
      final bd = ByteData.sublistView(bytes);
      final data = bd.getUint32(0, Endian.little);
      final mv = bd.getUint16(4, Endian.little);
      return _TestNode(data >> 30, data & 0x3fffffff, decodeMove(mv));
    }

    // Traverse root children: exactly 17 blunder responses
    final rootChildren = <String>[];
    var curr = 1;
    while (curr > 0 && curr < nodeCount) {
      final node = await readNode(curr);
      rootChildren.add(node.mv);
      expect(node.w, equals(1), reason: 'Each blunder is an internal branch node');
      curr = node.d;
    }

    expect(rootChildren.length, equals(17));
    expect(rootChildren, contains('a7a6'));
    expect(rootChildren, contains('d7d5'));
    expect(rootChildren, contains('f7f5'));
    expect(rootChildren, contains('b8c6'));

    // Verify first blunder (1... a6 at Node 1)
    // Child is White's reply 2. Ne5 at Node 2
    final whiteNode = await readNode(2);
    expect(whiteNode.mv, equals('f3e5'));
    expect(whiteNode.w, equals(1));

    await raf.close();
  });
}
