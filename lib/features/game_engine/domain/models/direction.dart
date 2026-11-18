enum Direction {
  north, // Up on the spinner
  south, // Down on the spinner
  east,  // Right on the line
  west,  // Left on the line
}

extension DirectionExtension on Direction {
  Direction get opposite {
    switch (this) {
      case Direction.north:
        return Direction.south;
      case Direction.south:
        return Direction.north;
      case Direction.east:
        return Direction.west;
      case Direction.west:
        return Direction.east;
    }
  }

  bool get isVertical => this == Direction.north || this == Direction.south;
  bool get isHorizontal => this == Direction.east || this == Direction.west;
}
