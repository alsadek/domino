import 'domino_tile.dart';
import 'open_end.dart';

enum MoveType {
  playTile,
  drawFromBoneyard,
  pass,
}

class Move {
  final MoveType type;
  final DominoTile? tile;
  final OpenEnd? targetEnd;
  final bool flipTile; // If true, tile is oriented [tail | head] instead of [head | tail]

  const Move._({
    required this.type,
    this.tile,
    this.targetEnd,
    this.flipTile = false,
  });

  factory Move.play({
    required DominoTile tile,
    required OpenEnd? targetEnd,
    bool flipTile = false,
  }) {
    return Move._(
      type: MoveType.playTile,
      tile: tile,
      targetEnd: targetEnd,
      flipTile: flipTile,
    );
  }

  factory Move.draw() {
    return const Move._(type: MoveType.drawFromBoneyard);
  }

  factory Move.pass() {
    return const Move._(type: MoveType.pass);
  }

  @override
  String toString() {
    switch (type) {
      case MoveType.playTile:
        return 'Play(${tile!.egyptianName} -> $targetEnd)';
      case MoveType.drawFromBoneyard:
        return 'Draw(سحب)';
      case MoveType.pass:
        return 'Pass(باص)';
    }
  }
}
