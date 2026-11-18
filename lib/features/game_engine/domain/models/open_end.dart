import 'board_node.dart';
import 'direction.dart';

class OpenEnd {
  final BoardNode node;
  final Direction attachDirection;
  final Direction branch;
  final int exposedPip;

  const OpenEnd({
    required this.node,
    required this.attachDirection,
    required this.exposedPip,
    Direction? branch,
  }) : branch = branch ?? attachDirection;

  /// The pip value this end contributes to the active board sum
  int get scoringContribution {
    // If the leaf node is a double (played crosswise at an open end)
    // and is NOT the spinner itself, it counts both ends (its full pipSum).
    if (node.tile.isDouble && !node.isSpinner) {
      return node.tile.pipSum;
    }
    return exposedPip;
  }

  @override
  String toString() =>
      'OpenEnd(pip: $exposedPip, dir: $attachDirection, tile: ${node.tile})';
}
