import '../models/board_node.dart';
import '../models/direction.dart';
import '../models/domino_tile.dart';
import '../models/open_end.dart';

class GameBoard {
  static const double standardTileThickness = 40.0;
  static const double standardTileLength = 80.0;
  static const int maxHorizontalTilesBeforeTurn = 5;

  BoardNode? rootNode;
  BoardNode? spinnerNode;
  final List<OpenEnd> _openEnds = [];
  final List<BoardNode> _allNodes = [];

  GameBoard();

  List<OpenEnd> get openEnds => List.unmodifiable(_openEnds);
  List<BoardNode> get allNodes => List.unmodifiable(_allNodes);
  bool get isEmpty => rootNode == null;
  bool get hasSpinner => spinnerNode != null;

  bool get isSpinnerFullyCrossed {
    if (spinnerNode == null) return false;
    final s = spinnerNode!;
    return s.east != null && s.west != null && s.north != null && s.south != null;
  }

  void placeFirstTile(DominoTile tile) {
    assert(isEmpty, 'Cannot place first tile on a non-empty board');

    final isDouble = tile.isDouble;
    final orientation = isDouble ? TileOrientation.vertical : TileOrientation.horizontal;
    final width = isDouble ? standardTileThickness : standardTileLength;
    final height = isDouble ? standardTileLength : standardTileThickness;

    final node = BoardNode(
      tile: tile,
      isSpinner: isDouble,
      pixelX: 0.0,
      pixelY: 0.0,
      width: width,
      height: height,
      orientation: orientation,
      innerPip: null,
      outerPip: null,
      displayedHead: tile.head,
      displayedTail: tile.tail,
    );

    rootNode = node;
    _allNodes.add(node);

    if (isDouble) {
      spinnerNode = node;
      // All 4 arms of the Spinner are initially open!
      _openEnds.add(OpenEnd(
        node: node,
        attachDirection: Direction.east,
        exposedPip: tile.head,
      ));
      _openEnds.add(OpenEnd(
        node: node,
        attachDirection: Direction.west,
        exposedPip: tile.head,
      ));
      _openEnds.add(OpenEnd(
        node: node,
        attachDirection: Direction.north,
        exposedPip: tile.head,
      ));
      _openEnds.add(OpenEnd(
        node: node,
        attachDirection: Direction.south,
        exposedPip: tile.head,
      ));
    } else {
      _openEnds.add(OpenEnd(
        node: node,
        attachDirection: Direction.east,
        exposedPip: tile.tail,
      ));
      _openEnds.add(OpenEnd(
        node: node,
        attachDirection: Direction.west,
        exposedPip: tile.head,
      ));
    }
  }

  List<OpenEnd> findLegalPlacements(DominoTile tile) {
    if (isEmpty) return [];

    final legal = <OpenEnd>[];
    for (final end in _openEnds) {
      if (tile.hasPip(end.exposedPip)) {
        legal.add(end);
      }
    }
    return legal;
  }

  BoardNode playTile({
    required DominoTile tile,
    required OpenEnd targetEnd,
  }) {
    assert(_openEnds.contains(targetEnd), 'targetEnd is not currently open');
    assert(tile.hasPip(targetEnd.exposedPip), 'Tile does not match exposed pip');

    final connectPip = targetEnd.exposedPip;
    final outerPip = (tile.head == connectPip) ? tile.tail : tile.head;

    TileOrientation orientation;
    double childWidth;
    double childHeight;
    int displayedHead;
    int displayedTail;

    switch (targetEnd.attachDirection) {
      case Direction.east:
        orientation = tile.isDouble ? TileOrientation.vertical : TileOrientation.horizontal;
        childWidth = tile.isDouble ? standardTileThickness : standardTileLength;
        childHeight = tile.isDouble ? standardTileLength : standardTileThickness;
        displayedHead = connectPip; // Left touches neighbor
        displayedTail = outerPip;   // Right faces open
        break;

      case Direction.west:
        orientation = tile.isDouble ? TileOrientation.vertical : TileOrientation.horizontal;
        childWidth = tile.isDouble ? standardTileThickness : standardTileLength;
        childHeight = tile.isDouble ? standardTileLength : standardTileThickness;
        displayedHead = outerPip;   // Left faces open
        displayedTail = connectPip; // Right touches neighbor
        break;

      case Direction.north:
        orientation = tile.isDouble ? TileOrientation.horizontal : TileOrientation.vertical;
        childWidth = tile.isDouble ? standardTileLength : standardTileThickness;
        childHeight = tile.isDouble ? standardTileThickness : standardTileLength;
        displayedHead = outerPip;   // Top faces open
        displayedTail = connectPip; // Bottom touches neighbor
        break;

      case Direction.south:
        orientation = tile.isDouble ? TileOrientation.horizontal : TileOrientation.vertical;
        childWidth = tile.isDouble ? standardTileLength : standardTileThickness;
        childHeight = tile.isDouble ? standardTileThickness : standardTileLength;
        displayedHead = connectPip; // Top touches neighbor
        displayedTail = outerPip;   // Bottom faces open
        break;
    }

    // Exact edge-to-edge physical alignment
    double childX = targetEnd.node.pixelX;
    double childY = targetEnd.node.pixelY;
    final parentWidth = targetEnd.node.width;
    final parentHeight = targetEnd.node.height;

    if (targetEnd.attachDirection == Direction.east && targetEnd.node == spinnerNode?.north) {
      // Turning East from North branch (elbow turn after 1 vertical tile):
      // Align vertically with the top half of Tile 1 North (where outerPip is)
      childX += (parentWidth / 2) + (childWidth / 2);
      childY -= 20.0;
    } else if (targetEnd.attachDirection == Direction.west && targetEnd.node == spinnerNode?.south) {
      // Turning West from South branch (elbow turn after 1 vertical tile):
      // Align vertically with the bottom half of Tile 1 South (where outerPip is)
      childX -= (parentWidth / 2) + (childWidth / 2);
      childY += 20.0;
    } else if (targetEnd.attachDirection == Direction.south &&
        targetEnd.branch == Direction.east &&
        targetEnd.node.orientation == TileOrientation.horizontal) {
      // Turning South from East branch (elbow turn after 4 horizontal tiles):
      // Align horizontally with the right half of Tile 4 East (where outerPip is)
      childX += 20.0;
      childY += (parentHeight / 2) + (childHeight / 2);
    } else if (targetEnd.attachDirection == Direction.north &&
        targetEnd.branch == Direction.west &&
        targetEnd.node.orientation == TileOrientation.horizontal) {
      // Turning North from West branch (elbow turn after 4 horizontal tiles):
      // Align horizontally with the left half of Tile 4 West (where outerPip is)
      childX -= 20.0;
      childY -= (parentHeight / 2) + (childHeight / 2);
    } else {
      switch (targetEnd.attachDirection) {
        case Direction.east:
          childX += (parentWidth / 2) + (childWidth / 2);
          break;
        case Direction.west:
          childX -= (parentWidth / 2) + (childWidth / 2);
          break;
        case Direction.north:
          childY -= (parentHeight / 2) + (childHeight / 2);
          break;
        case Direction.south:
          childY += (parentHeight / 2) + (childHeight / 2);
          break;
      }
    }

    final newNode = BoardNode(
      tile: tile,
      isSpinner: false,
      pixelX: childX,
      pixelY: childY,
      width: childWidth,
      height: childHeight,
      orientation: orientation,
      innerPip: connectPip,
      outerPip: outerPip,
      displayedHead: displayedHead,
      displayedTail: displayedTail,
    );

    // Link nodes together
    targetEnd.node.attachNode(targetEnd.attachDirection, newNode);
    newNode.attachNode(targetEnd.attachDirection.opposite, targetEnd.node);

    _allNodes.add(newNode);
    _openEnds.remove(targetEnd);

    if (isSpinnerFullyCrossed) {
      _unlockAllTerminalBranchEnds();
    }

    return newNode;
  }

  void _unlockAllTerminalBranchEnds() {
    _openEnds.clear();
    final s = spinnerNode;
    if (s == null) return;

    // 1. East Branch: up to 6 tiles East from spinner, then turns South
    BoardNode eastCur = s;
    int eastCount = 0;
    while (eastCur.east != null && eastCount < maxHorizontalTilesBeforeTurn) {
      eastCur = eastCur.east!;
      eastCount++;
    }
    if (eastCount >= maxHorizontalTilesBeforeTurn) {
      while (eastCur.south != null) {
        eastCur = eastCur.south!;
      }
    }
    if (eastCur != s) {
      _openEnds.add(OpenEnd(
        node: eastCur,
        attachDirection: eastCount < maxHorizontalTilesBeforeTurn ? Direction.east : Direction.south,
        branch: Direction.east,
        exposedPip: eastCur.outerPip ?? eastCur.tile.head,
      ));
    }

    // 2. West Branch: up to 6 tiles West from spinner, then turns North
    BoardNode westCur = s;
    int westCount = 0;
    while (westCur.west != null && westCount < maxHorizontalTilesBeforeTurn) {
      westCur = westCur.west!;
      westCount++;
    }
    if (westCount >= maxHorizontalTilesBeforeTurn) {
      while (westCur.north != null) {
        westCur = westCur.north!;
      }
    }
    if (westCur != s) {
      _openEnds.add(OpenEnd(
        node: westCur,
        attachDirection: westCount < maxHorizontalTilesBeforeTurn ? Direction.west : Direction.north,
        branch: Direction.west,
        exposedPip: westCur.outerPip ?? westCur.tile.head,
      ));
    }

    // 3. North Branch: 1 tile North from spinner, then extends horizontally East (parallel track)
    final northFirst = s.north;
    if (northFirst != null) {
      BoardNode northCur = northFirst;
      while (northCur.east != null) {
        northCur = northCur.east!;
      }
      _openEnds.add(OpenEnd(
        node: northCur,
        attachDirection: Direction.east,
        branch: Direction.north,
        exposedPip: northCur.outerPip ?? northCur.tile.head,
      ));
    }

    // 4. South Branch: 1 tile South from spinner, then extends horizontally West (parallel track)
    final southFirst = s.south;
    if (southFirst != null) {
      BoardNode southCur = southFirst;
      while (southCur.west != null) {
        southCur = southCur.west!;
      }
      _openEnds.add(OpenEnd(
        node: southCur,
        attachDirection: Direction.west,
        branch: Direction.south,
        exposedPip: southCur.outerPip ?? southCur.tile.head,
      ));
    }
  }

  int calculateProjectedScore(OpenEnd targetEnd, DominoTile tile) {
    final connectPip = targetEnd.exposedPip;
    final outerPip = (tile.head == connectPip) ? tile.tail : tile.head;

    if (!isSpinnerFullyCrossed && _openEnds.length > 1) {
      return 0;
    }

    if (!isSpinnerFullyCrossed && _openEnds.length == 1) {
      int total = outerPip;
      final s = spinnerNode!;
      for (final dir in [Direction.east, Direction.west, Direction.north, Direction.south]) {
        if (dir != targetEnd.attachDirection) {
          final child = s.getNodeInDirection(dir);
          if (child != null) {
            total += (child.outerPip ?? child.tile.head);
          }
        }
      }
      return (total > 0 && total % 5 == 0) ? (total ~/ 5) : 0;
    }

    int total = 0;
    for (final existing in _openEnds) {
      if (existing == targetEnd) {
        if (tile.isDouble) {
          total += tile.pipSum;
        } else {
          total += outerPip;
        }
      } else {
        total += existing.scoringContribution;
      }
    }
    return (total > 0 && total % 5 == 0) ? (total ~/ 5) : 0;
  }

  List<OpenEnd> getScoringEnds() {
    if (!isSpinnerFullyCrossed) {
      return const [];
    }
    return _openEnds;
  }
}
