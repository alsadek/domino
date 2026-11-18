import 'package:flutter/material.dart';

class DominoPipsPainter extends CustomPainter {
  final int topOrLeftPips;
  final int bottomOrRightPips;
  final bool isVertical;
  final Color pipColor;
  final Color dividerColor;

  DominoPipsPainter({
    required this.topOrLeftPips,
    required this.bottomOrRightPips,
    this.isVertical = true,
    this.pipColor = const Color(0xFF1E1E1E), // Deep charcoal / engraved black
    this.dividerColor = const Color(0xFF8B6F3E), // Classic brass / vintage groove
  });

  @override
  void paint(Canvas canvas, Size size) {
    final pipPaint = Paint()
      ..color = pipColor
      ..style = PaintingStyle.fill;

    final dividerPaint = Paint()
      ..color = dividerColor
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;

    final brassPinPaint = Paint()
      ..color = const Color(0xFFD4AF37) // Metallic brass center pin
      ..style = PaintingStyle.fill;

    if (isVertical) {
      final halfHeight = size.height / 2;
      final topRect = Rect.fromLTWH(0, 0, size.width, halfHeight);
      final bottomRect = Rect.fromLTWH(0, halfHeight, size.width, halfHeight);

      // Draw center dividing groove
      canvas.drawLine(
        Offset(size.width * 0.12, halfHeight),
        Offset(size.width * 0.88, halfHeight),
        dividerPaint,
      );

      // Classic center brass pin (المسمار النحاس)
      canvas.drawCircle(Offset(size.width / 2, halfHeight), 2.2, brassPinPaint);

      // Draw pips on both halves
      _drawHalfPips(canvas, topRect, topOrLeftPips, pipPaint);
      _drawHalfPips(canvas, bottomRect, bottomOrRightPips, pipPaint);
    } else {
      final halfWidth = size.width / 2;
      final leftRect = Rect.fromLTWH(0, 0, halfWidth, size.height);
      final rightRect = Rect.fromLTWH(halfWidth, 0, halfWidth, size.height);

      // Draw center dividing groove
      canvas.drawLine(
        Offset(halfWidth, size.height * 0.12),
        Offset(halfWidth, size.height * 0.88),
        dividerPaint,
      );

      // Classic center brass pin
      canvas.drawCircle(Offset(halfWidth, size.height / 2), 2.2, brassPinPaint);

      _drawHalfPips(canvas, leftRect, topOrLeftPips, pipPaint);
      _drawHalfPips(canvas, rightRect, bottomOrRightPips, pipPaint);
    }
  }

  void _drawHalfPips(Canvas canvas, Rect rect, int count, Paint paint) {
    if (count <= 0) return;

    final radius = rect.shortestSide * 0.085;
    final cx = rect.center.dx;
    final cy = rect.center.dy;

    // Relative padding for 3x3 grid inside the half
    final px = rect.width * 0.26;
    final py = rect.height * 0.26;

    final left = cx - px;
    final right = cx + px;
    final top = cy - py;
    final bottom = cy + py;

    switch (count) {
      case 1:
        canvas.drawCircle(Offset(cx, cy), radius, paint);
        break;
      case 2:
        canvas.drawCircle(Offset(left, top), radius, paint);
        canvas.drawCircle(Offset(right, bottom), radius, paint);
        break;
      case 3:
        canvas.drawCircle(Offset(left, top), radius, paint);
        canvas.drawCircle(Offset(cx, cy), radius, paint);
        canvas.drawCircle(Offset(right, bottom), radius, paint);
        break;
      case 4:
        canvas.drawCircle(Offset(left, top), radius, paint);
        canvas.drawCircle(Offset(right, top), radius, paint);
        canvas.drawCircle(Offset(left, bottom), radius, paint);
        canvas.drawCircle(Offset(right, bottom), radius, paint);
        break;
      case 5:
        canvas.drawCircle(Offset(left, top), radius, paint);
        canvas.drawCircle(Offset(right, top), radius, paint);
        canvas.drawCircle(Offset(cx, cy), radius, paint);
        canvas.drawCircle(Offset(left, bottom), radius, paint);
        canvas.drawCircle(Offset(right, bottom), radius, paint);
        break;
      case 6:
        canvas.drawCircle(Offset(left, top), radius, paint);
        canvas.drawCircle(Offset(right, top), radius, paint);
        canvas.drawCircle(Offset(left, cy), radius, paint);
        canvas.drawCircle(Offset(right, cy), radius, paint);
        canvas.drawCircle(Offset(left, bottom), radius, paint);
        canvas.drawCircle(Offset(right, bottom), radius, paint);
        break;
    }
  }

  @override
  bool shouldRepaint(covariant DominoPipsPainter oldDelegate) {
    return oldDelegate.topOrLeftPips != topOrLeftPips ||
        oldDelegate.bottomOrRightPips != bottomOrRightPips ||
        oldDelegate.isVertical != isVertical ||
        oldDelegate.pipColor != pipColor;
  }
}
