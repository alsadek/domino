import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../game_engine/domain/models/board_node.dart';
import '../../../game_engine/domain/models/direction.dart';
import '../../../game_engine/domain/models/domino_tile.dart';
import '../../../game_engine/domain/models/open_end.dart';
import '../../../game_engine/domain/rules/game_board.dart';
import 'domino_tile_widget.dart';

class BoardCanvasWidget extends StatefulWidget {
  final GameBoard board;
  final DominoTile? selectedTile;
  final Function(OpenEnd end)? onSelectTargetEnd;
  final VoidCallback? onTableTapped;

  const BoardCanvasWidget({
    super.key,
    required this.board,
    this.selectedTile,
    this.onSelectTargetEnd,
    this.onTableTapped,
  });

  @override
  State<BoardCanvasWidget> createState() => _BoardCanvasWidgetState();
}

class _BoardCanvasWidgetState extends State<BoardCanvasWidget> {
  late TransformationController _transformationController;
  static const double worldSize = 2800.0;
  int _lastNodeCount = -1;
  double _lastVpWidth = 0;
  double _lastVpHeight = 0;

  @override
  void initState() {
    super.initState();
    _transformationController = TransformationController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleFitCheck();
  }

  @override
  void didUpdateWidget(covariant BoardCanvasWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleFitCheck();
  }

  void _scheduleFitCheck() {
    final currentCount = widget.board.allNodes.length;
    if (_lastNodeCount != currentCount) {
      _lastNodeCount = currentCount;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) fitAllTiles();
      });
    }
  }

  @override
  void dispose() {
    _transformationController.dispose();
    super.dispose();
  }

  void _recenterView() {
    final box = context.findRenderObject() as RenderBox?;
    final vpWidth = box?.size.width ?? 400.0;
    final vpHeight = box?.size.height ?? 600.0;

    final initialX = -(worldSize / 2 - vpWidth / 2);
    final initialY = -(worldSize / 2 - vpHeight / 2);

    _transformationController.value = Matrix4.translationValues(initialX, initialY, 0.0);
  }

  void fitAllTiles() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final vpWidth = box.size.width;
    final vpHeight = box.size.height;
    if (vpWidth <= 0 || vpHeight <= 0) return;

    if (widget.board.isEmpty) {
      _recenterView();
      return;
    }

    double minX = 0;
    double maxX = 0;
    double minY = 0;
    double maxY = 0;

    for (final node in widget.board.allNodes) {
      final left = node.pixelX - (node.width / 2);
      final right = node.pixelX + (node.width / 2);
      final top = node.pixelY - (node.height / 2);
      final bottom = node.pixelY + (node.height / 2);

      if (left < minX) minX = left;
      if (right > maxX) maxX = right;
      if (top < minY) minY = top;
      if (bottom > maxY) maxY = bottom;
    }

    // Include open-end drop zones so playable ends stay visible without manual zooming
    for (final end in widget.board.openEnds) {
      const slotPad = 76.0;
      final nx = end.node.pixelX + (end.attachDirection == Direction.east ? slotPad : (end.attachDirection == Direction.west ? -slotPad : 0));
      final ny = end.node.pixelY + (end.attachDirection == Direction.south ? slotPad : (end.attachDirection == Direction.north ? -slotPad : 0));
      if (nx < minX) minX = nx;
      if (nx > maxX) maxX = nx;
      if (ny < minY) minY = ny;
      if (ny > maxY) maxY = ny;
    }

    const margin = 28.0;
    minX -= margin;
    maxX += margin;
    minY -= margin;
    maxY += margin;

    final spanW = (maxX - minX).clamp(180.0, worldSize);
    final spanH = (maxY - minY).clamp(180.0, worldSize);

    final scaleX = vpWidth / spanW;
    final scaleY = vpHeight / spanH;
    final fitScale = (scaleX < scaleY ? scaleX : scaleY).clamp(0.15, 1.45);

    final midX = (minX + maxX) / 2;
    final midY = (minY + maxY) / 2;

    final canvasMidX = (worldSize / 2) + midX;
    final canvasMidY = (worldSize / 2) + midY;

    final transX = (vpWidth / 2) - (canvasMidX * fitScale);
    final transY = (vpHeight / 2) - (canvasMidY * fitScale);

    _transformationController.value = Matrix4.translationValues(transX, transY, 0.0)
      ..scaleByDouble(fitScale, fitScale, 1.0, 1.0);
  }

  void _zoomBy(double factor) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final center = Offset(box.size.width / 2, box.size.height / 2);
    final current = _transformationController.value;
    final currentScale = current.getMaxScaleOnAxis();
    final targetScale = (currentScale * factor).clamp(0.15, 2.5);
    final effectiveFactor = targetScale / currentScale;

    final sceneCenter = _transformationController.toScene(center);
    final nextMatrix = current.clone()
      ..translateByDouble(sceneCenter.dx, sceneCenter.dy, 0.0, 1.0)
      ..scaleByDouble(effectiveFactor, effectiveFactor, 1.0, 1.0)
      ..translateByDouble(-sceneCenter.dx, -sceneCenter.dy, 0.0, 1.0);

    _transformationController.value = nextMatrix;
  }

  void _zoomIn() => _zoomBy(1.25);

  void _zoomOut() => _zoomBy(0.8);

  @override
  Widget build(BuildContext context) {
    const centerOffset = Offset(worldSize / 2, worldSize / 2);

    // Re-fit automatically whenever a tile is added/reset or viewport rotates/resizes
    return LayoutBuilder(
      builder: (context, constraints) {
        final nodeCount = widget.board.allNodes.length;
        final vpChanged = (constraints.maxWidth - _lastVpWidth).abs() > 2 ||
            (constraints.maxHeight - _lastVpHeight).abs() > 2;
        if (_lastNodeCount != nodeCount || vpChanged) {
          _lastNodeCount = nodeCount;
          _lastVpWidth = constraints.maxWidth;
          _lastVpHeight = constraints.maxHeight;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) fitAllTiles();
          });
        }

        final legalEnds = widget.selectedTile != null
            ? widget.board.findLegalPlacements(widget.selectedTile!)
            : <OpenEnd>[];

        final safeLeft = MediaQuery.of(context).padding.left;

        return Container(
          color: const Color(0xFF1B2817),
          child: Stack(
            children: [
              // Interactive Canvas with 2800x2800 hit test area
              InteractiveViewer(
                transformationController: _transformationController,
                constrained: false,
                boundaryMargin: const EdgeInsets.all(1200),
                minScale: 0.15,
                maxScale: 2.5,
            child: GestureDetector(
              onTap: widget.onTableTapped,
              child: Container(
                width: worldSize,
                height: worldSize,
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment.center,
                    radius: 0.95,
                    colors: [
                      Color(0xFF283B23), // Vibrant Felt center
                      Color(0xFF1F2F1B),
                      Color(0xFF192616),
                      Color(0xFF131D11), // Seamless deep felt rim
                    ],
                  ),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    _buildCenterTableDecorations(centerOffset),

                    // Prompt when board is empty
                    if (widget.board.isEmpty)
                      Positioned(
                        left: centerOffset.dx - 140,
                        top: centerOffset.dy - 24,
                        child: Container(
                          width: 280,
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          decoration: BoxDecoration(
                            color: const Color(0xFF19110B).withValues(alpha: 0.9),
                            borderRadius: BorderRadius.circular(24),
                            border: Border.all(color: const Color(0xFFD4AF37), width: 1.5),
                          ),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.touch_app, size: 18, color: Color(0xFFD4AF37)),
                                const SizedBox(width: 8),
                                Text(
                                  'اختر بفّة من يدك لبدء اللعبة',
                                  style: GoogleFonts.cairo(
                                    color: const Color(0xFFD4AF37),
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                    // Placed Domino Tiles with Seamless Physical Edges
                    for (final node in widget.board.allNodes)
                      _buildPlacedTile(node, centerOffset),

                    // Legal Snap Targets (Open Ends)
                    for (final end in legalEnds)
                      _buildTargetSlot(end, centerOffset),
                  ],
                ),
              ),
            ),
          ),

          // Floating View Controls moved to Top-Right as a compact horizontal row
          Positioned(
            right: 14,
            top: 10,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildControlBtn(
                  icon: Icons.fit_screen,
                  tooltip: 'احتواء الطاولة بالكامل',
                  onTap: fitAllTiles,
                ),
                const SizedBox(width: 5),
                _buildControlBtn(
                  icon: Icons.filter_center_focus,
                  tooltip: 'إعادة ضبط للمنتصف',
                  onTap: _recenterView,
                ),
                const SizedBox(width: 5),
                _buildControlBtn(
                  icon: Icons.add,
                  tooltip: 'تكبير',
                  onTap: _zoomIn,
                ),
                const SizedBox(width: 5),
                _buildControlBtn(
                  icon: Icons.remove,
                  tooltip: 'تصغير',
                  onTap: _zoomOut,
                ),
              ],
            ),
          ),

          // Table Status Indicator (Shown only before cross is complete, success mark removed)
          if (!widget.board.isEmpty && !widget.board.isSpinnerFullyCrossed)
            Positioned(
              left: 14 + safeLeft,
              top: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: const Color(0xFFFFB300),
                    width: 1.2,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.radio_button_checked,
                      size: 14,
                      color: Color(0xFFFFB300),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'تقفيل الاتجاهات أولاً (${widget.board.openEnds.length} متبقية)',
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
  }

  Widget _buildControlBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Material(
      color: const Color(0xFF2C1E14).withValues(alpha: 0.88),
      borderRadius: BorderRadius.circular(8),
      elevation: 4,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFF8B6F3E), width: 1.2),
          ),
          child: Icon(icon, size: 17, color: const Color(0xFFD4AF37)),
        ),
      ),
    );
  }

  Widget _buildCenterTableDecorations(Offset center) {
    return Positioned(
      left: center.dx - 160,
      top: center.dy - 160,
      child: IgnorePointer(
        child: SizedBox(
          width: 320,
          height: 320,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Container(
                width: 300,
                height: 300,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFD4AF37).withValues(alpha: 0.12),
                    width: 2,
                  ),
                ),
              ),
              Container(
                width: 220,
                height: 220,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: const Color(0xFFD4AF37).withValues(alpha: 0.08),
                    width: 1.5,
                  ),
                ),
              ),
              Container(
                width: 1,
                height: 280,
                color: const Color(0xFFD4AF37).withValues(alpha: 0.08),
              ),
              Container(
                width: 280,
                height: 1,
                color: const Color(0xFFD4AF37).withValues(alpha: 0.08),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlacedTile(BoardNode node, Offset center) {
    final posX = center.dx + node.pixelX - (node.width / 2);
    final posY = center.dy + node.pixelY - (node.height / 2);

    return Positioned(
      left: posX,
      top: posY,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          DominoTileWidget(
            tile: DominoTile(node.displayedHead, node.displayedTail, id: node.tile.id),
            orientation: node.orientation,
            width: GameBoard.standardTileThickness,
            height: GameBoard.standardTileLength,
          ),
          if (node.isSpinner)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFFFB300),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.amber.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
                child: const Icon(Icons.star, size: 10, color: Colors.black),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTargetSlot(OpenEnd end, Offset center) {
    final parent = end.node;
    double targetX = parent.pixelX;
    double targetY = parent.pixelY;

    const childLength = GameBoard.standardTileLength;
    double offsetDist = 0.0;

    if (end.attachDirection == Direction.east && parent == widget.board.spinnerNode?.north) {
      targetX += (parent.width / 2) + (childLength / 2);
      targetY -= 20.0;
    } else if (end.attachDirection == Direction.west && parent == widget.board.spinnerNode?.south) {
      targetX -= (parent.width / 2) + (childLength / 2);
      targetY += 20.0;
    } else if (end.attachDirection == Direction.south &&
        end.branch == Direction.east &&
        parent.orientation == TileOrientation.horizontal) {
      targetX += 20.0;
      targetY += (parent.height / 2) + (childLength / 2);
    } else if (end.attachDirection == Direction.north &&
        end.branch == Direction.west &&
        parent.orientation == TileOrientation.horizontal) {
      targetX -= 20.0;
      targetY -= (parent.height / 2) + (childLength / 2);
    } else {
      switch (end.attachDirection) {
        case Direction.east:
          offsetDist = (parent.width / 2) + (childLength / 2);
          targetX += offsetDist;
          break;
        case Direction.west:
          offsetDist = (parent.width / 2) + (childLength / 2);
          targetX -= offsetDist;
          break;
        case Direction.north:
          offsetDist = (parent.height / 2) + (childLength / 2);
          targetY -= offsetDist;
          break;
        case Direction.south:
          offsetDist = (parent.height / 2) + (childLength / 2);
          targetY += offsetDist;
          break;
      }
    }

    const slotSize = 52.0;
    final posX = center.dx + targetX - (slotSize / 2);
    final posY = center.dy + targetY - (slotSize / 2);

    return Positioned(
      left: posX,
      top: posY,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onSelectTargetEnd?.call(end),
        child: Container(
          width: slotSize,
          height: slotSize,
          decoration: BoxDecoration(
            color: const Color(0xFF4CAF50).withValues(alpha: 0.4),
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF81C784),
              width: 2.4,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF4CAF50).withValues(alpha: 0.6),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Center(
            child: Text(
              '${end.exposedPip}',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
