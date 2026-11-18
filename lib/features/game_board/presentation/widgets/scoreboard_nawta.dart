import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../../game_engine/domain/models/player.dart';

class ScoreboardNawtaWidget extends StatelessWidget {
  final List<Player> players;
  final int activePlayerIndex;
  final int targetScore;
  final int roundNumber;
  final VoidCallback? onOpenHistory;

  const ScoreboardNawtaWidget({
    super.key,
    required this.players,
    required this.activePlayerIndex,
    required this.targetScore,
    required this.roundNumber,
    this.onOpenHistory,
  });

  static const List<Color> playerColors = [
    Color(0xFF2E7D32), // Player 1: Green
    Color(0xFFC62828), // Player 2: Red
    Color(0xFF1565C0), // Player 3: Blue
    Color(0xFFE65100), // Player 4: Orange
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 6.0),
      decoration: BoxDecoration(
        color: const Color(0xFFFBF8EE), // Notebook paper texture
        borderRadius: BorderRadius.circular(10.0),
        border: Border.all(color: const Color(0xFFC7BBA5), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header: Target, Round, and History Button
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Text(
                    'النوتة (الهدف: $targetScore)',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF4A3B2C),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8DFCC),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      'الدور $roundNumber',
                      style: GoogleFonts.cairo(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF3E2D1F),
                      ),
                    ),
                  ),
                ],
              ),
              if (onOpenHistory != null)
                InkWell(
                  onTap: onOpenHistory,
                  child: Row(
                    children: [
                      const Icon(Icons.history_edu, size: 14, color: Color(0xFF8B6F3E)),
                      const SizedBox(width: 4),
                      Text(
                        'سجل البولات',
                        style: GoogleFonts.cairo(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF8B6F3E),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Container(height: 1, color: const Color(0xFFD6C8B2)),
          const SizedBox(height: 6),

          // Scores Row (Supports 2, 3, or 4 players)
          Row(
            children: [
              for (int i = 0; i < players.length; i++) ...[
                if (i > 0)
                  Container(
                    width: 1,
                    height: 20,
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    color: const Color(0xFFD6C8B2),
                  ),
                Expanded(
                  child: _buildPlayerScoreChip(
                    player: players[i],
                    color: playerColors[i % playerColors.length],
                    isActive: i == activePlayerIndex,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerScoreChip({
    required Player player,
    required Color color,
    required bool isActive,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: isActive ? color.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isActive ? color : Colors.transparent,
          width: 1.2,
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              player.name,
              style: GoogleFonts.cairo(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                color: const Color(0xFF2D2319),
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${player.score}',
            style: GoogleFonts.cairo(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
