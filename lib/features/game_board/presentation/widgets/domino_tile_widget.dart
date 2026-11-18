import 'package:flutter/material.dart';
import '../../../game_engine/domain/models/board_node.dart';
import '../../../game_engine/domain/models/domino_tile.dart';
import '../painters/domino_painter.dart';

class DominoTileWidget extends StatelessWidget {
  final DominoTile tile;
  final TileOrientation orientation;
  final bool isFaceDown;
  final bool isSelected;
  final bool isPlayable;
  final double width;
  final double height;
  final VoidCallback? onTap;

  const DominoTileWidget({
    super.key,
    required this.tile,
    this.orientation = TileOrientation.vertical,
    this.isFaceDown = false,
    this.isSelected = false,
    this.isPlayable = false,
    this.width = 46.0,
    this.height = 92.0,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final actualWidth = orientation == TileOrientation.vertical ? width : height;
    final actualHeight = orientation == TileOrientation.vertical ? height : width;

    Widget content;

    if (isFaceDown) {
      content = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.0),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF2C1E14), // Dark mahogany / vintage back
              Color(0xFF19110B),
            ],
          ),
          border: Border.all(
            color: const Color(0xFF5A3E26),
            width: 1.5,
          ),
        ),
        child: Center(
          child: Container(
            width: actualWidth * 0.45,
            height: actualHeight * 0.45,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF8B6F3E), width: 1.2),
            ),
            child: const Icon(
              Icons.stars,
              size: 14,
              color: Color(0xFF8B6F3E),
            ),
          ),
        ),
      );
    } else {
      content = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6.0),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFFFFFDF5), // Warm ivory bone finish
              Color(0xFFF3ECE0),
            ],
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 4.0,
              offset: const Offset(1.5, 3.0),
            ),
          ],
          border: Border.all(
            color: isSelected
                ? const Color(0xFFFFB300) // Vibrant Gold when selected
                : isPlayable
                    ? const Color(0xFF4CAF50) // Subtle Green glow when legal
                    : const Color(0xFFD4C7B5),
            width: isSelected ? 2.5 : (isPlayable ? 2.0 : 1.0),
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(5.0),
          child: CustomPaint(
            size: Size(actualWidth, actualHeight),
            painter: DominoPipsPainter(
              topOrLeftPips: tile.head,
              bottomOrRightPips: tile.tail,
              isVertical: orientation == TileOrientation.vertical,
            ),
          ),
        ),
      );
    }

    if (onTap != null) {
      return GestureDetector(
        onTap: onTap,
        child: content,
      );
    }

    return content;
  }
}
