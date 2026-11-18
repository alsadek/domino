import 'direction.dart';
import 'domino_tile.dart';

enum TileOrientation {
  horizontal, // Laid flat [ left | right ]
  vertical,   // Laid upright [ top / bottom ]
}

class BoardNode {
  final DominoTile tile;
  final bool isSpinner;
  final TileOrientation orientation;

  // Exact physical pixel coordinates relative to table center (0, 0)
  final double pixelX;
  final double pixelY;

  // Visual dimensions
  final double width;
  final double height;

  // The pip facing inward (connected to previous tile)
  final int? innerPip;
  // The pip facing outward (exposed to future tiles)
  final int? outerPip;

  // Visual pips rendered on screen:
  // Top (if vertical) or Left (if horizontal)
  final int displayedHead;
  // Bottom (if vertical) or Right (if horizontal)
  final int displayedTail;

  // Links to adjacent nodes
  BoardNode? north;
  BoardNode? south;
  BoardNode? east;
  BoardNode? west;

  BoardNode({
    required this.tile,
    this.isSpinner = false,
    required this.pixelX,
    required this.pixelY,
    required this.width,
    required this.height,
    required this.orientation,
    this.innerPip,
    this.outerPip,
    required this.displayedHead,
    required this.displayedTail,
  });

  bool canConnect(Direction dir) {
    if (!isSpinner && (dir == Direction.north || dir == Direction.south)) {
      return false;
    }
    switch (dir) {
      case Direction.north: return north == null;
      case Direction.south: return south == null;
      case Direction.east: return east == null;
      case Direction.west: return west == null;
    }
  }

  BoardNode? getNodeInDirection(Direction dir) {
    switch (dir) {
      case Direction.north: return north;
      case Direction.south: return south;
      case Direction.east: return east;
      case Direction.west: return west;
    }
  }

  void attachNode(Direction dir, BoardNode node) {
    switch (dir) {
      case Direction.north: north = node; break;
      case Direction.south: south = node; break;
      case Direction.east:  east = node;  break;
      case Direction.west:  west = node;  break;
    }
  }
}
