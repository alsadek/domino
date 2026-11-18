import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'match_history_manager.dart';

class MatchHistoryDialog extends StatefulWidget {
  final String? currentUserId;
  const MatchHistoryDialog({super.key, this.currentUserId});

  @override
  State<MatchHistoryDialog> createState() => _MatchHistoryDialogState();
}

class _MatchHistoryDialogState extends State<MatchHistoryDialog> {
  List<MatchRecord> _history = [];
  List<LeaderboardEntry> _leaderboard = [];
  bool _loading = true;
  bool _onlyMine = false;
  int _tabIndex = 0; // 0 = Matches, 1 = Leaderboard

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    setState(() => _loading = true);
    final payload = await MatchHistoryManager.getServerHistory(
      userId: (_onlyMine && widget.currentUserId != null) ? widget.currentUserId : null,
    );
    if (!mounted) return;
    setState(() {
      _history = payload.history;
      _leaderboard = payload.leaderboard;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2C1E14),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5),
      ),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.history_edu, color: Color(0xFFD4AF37), size: 22),
              const SizedBox(width: 8),
              Text(
                'سجل البولات والأصدقاء',
                style: GoogleFonts.cairo(
                  color: const Color(0xFFD4AF37),
                  fontSize: 15.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37), size: 20),
            tooltip: 'تحديث',
            onPressed: _loadHistory,
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        height: 410,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: ChoiceChip(
                    label: Center(
                      child: Text(
                        '📜 سجل البولات',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _tabIndex == 0 ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                    selected: _tabIndex == 0,
                    selectedColor: const Color(0xFFD4AF37),
                    backgroundColor: const Color(0xFF19110B),
                    onSelected: (_) => setState(() => _tabIndex = 0),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ChoiceChip(
                    label: Center(
                      child: Text(
                        '🏆 ترتيب الأصدقاء',
                        style: GoogleFonts.cairo(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: _tabIndex == 1 ? Colors.black : Colors.white,
                        ),
                      ),
                    ),
                    selected: _tabIndex == 1,
                    selectedColor: const Color(0xFFD4AF37),
                    backgroundColor: const Color(0xFF19110B),
                    onSelected: (_) => setState(() => _tabIndex = 1),
                  ),
                ),
              ],
            ),
            if (_tabIndex == 0 && widget.currentUserId != null) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilterChip(
                  label: Text(
                    'مبارياتي فقط',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _onlyMine ? Colors.black : Colors.white70,
                    ),
                  ),
                  selected: _onlyMine,
                  selectedColor: const Color(0xFFD4AF37),
                  backgroundColor: const Color(0xFF19110B),
                  visualDensity: VisualDensity.compact,
                  onSelected: (v) {
                    setState(() => _onlyMine = v);
                    _loadHistory();
                  },
                ),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: Color(0xFFD4AF37)))
                  : _tabIndex == 1
                      ? _buildLeaderboardList()
                      : _history.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.menu_book, size: 48, color: Colors.white24),
                                  const SizedBox(height: 12),
                                  Text(
                                    'لا يوجد بولات مسجلة حتى الآن.\nالعب بولة جديدة وستُحفظ هنا تلقائياً!',
                                    textAlign: TextAlign.center,
                                    style: GoogleFonts.cairo(color: Colors.white60, fontSize: 13),
                                  ),
                                ],
                              ),
                            )
                          : ListView.separated(
                              itemCount: _history.length,
                              separatorBuilder: (_, _) => const SizedBox(height: 10),
                              itemBuilder: (ctx, index) {
                                final record = _history[index];
                                final localDate = record.date.toLocal();
                                final dateStr =
                                    '${localDate.day}/${localDate.month}/${localDate.year} - ${localDate.hour}:${localDate.minute.toString().padLeft(2, '0')}';

                                return Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF19110B),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(color: const Color(0xFF5A3E26)),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                        children: [
                                          Row(
                                            children: [
                                              const Icon(Icons.emoji_events, size: 18, color: Color(0xFFD4AF37)),
                                              const SizedBox(width: 6),
                                              Text(
                                                'الفائز: ${record.winnerName}',
                                                style: GoogleFonts.cairo(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                  color: const Color(0xFFD4AF37),
                                                ),
                                              ),
                                            ],
                                          ),
                                          Text(
                                            dateStr,
                                            style: GoogleFonts.cairo(fontSize: 11, color: Colors.white38),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Text(
                                        'الهدف: ${record.targetScore} نقطة  •  عدد الأدوار: ${record.roundsPlayed}${record.roomCode != null ? "  •  غرفة #${record.roomCode}" : ""}',
                                        style: GoogleFonts.cairo(fontSize: 11, color: Colors.white54),
                                      ),
                                      const SizedBox(height: 8),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        children: record.players.map((p) {
                                          return Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: p.isWinner
                                                  ? const Color(0xFF2E7D32).withValues(alpha: 0.35)
                                                  : const Color(0xFF2C1E14),
                                              borderRadius: BorderRadius.circular(6),
                                              border: Border.all(
                                                color: p.isWinner ? Colors.green : Colors.white24,
                                              ),
                                            ),
                                            child: Text(
                                              '${p.name}: ${p.score}',
                                              style: GoogleFonts.cairo(
                                                fontSize: 12,
                                                fontWeight: p.isWinner ? FontWeight.bold : FontWeight.normal,
                                                color: p.isWinner ? Colors.greenAccent : Colors.white70,
                                              ),
                                            ),
                                          );
                                        }).toList(),
                                      ),
                                    ],
                                  ),
                                );
                              },
                            ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('إغلاق', style: GoogleFonts.cairo(color: const Color(0xFFD4AF37))),
        ),
      ],
    );
  }

  Widget _buildLeaderboardList() {
    if (_leaderboard.isEmpty) {
      return Center(
        child: Text(
          'سجل دخولك والعب بولات أونلاين ليظهر ترتيب الأصدقاء هنا',
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(color: Colors.white60, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      itemCount: _leaderboard.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (ctx, i) {
        final e = _leaderboard[i];
        final isMe = widget.currentUserId != null && e.userId == widget.currentUserId;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF19110B),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: isMe ? const Color(0xFFD4AF37) : const Color(0xFF5A3E26)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: i == 0 ? const Color(0xFFD4AF37) : Colors.white12,
                child: Text(
                  '${i + 1}',
                  style: GoogleFonts.cairo(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: i == 0 ? Colors.black : Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      e.displayName,
                      style: GoogleFonts.cairo(
                        fontSize: 13.5,
                        fontWeight: FontWeight.bold,
                        color: isMe ? const Color(0xFFD4AF37) : Colors.white,
                      ),
                    ),
                    Text(
                      '@${e.userId}  •  لعب: ${e.gamesPlayed}  •  نسبة الفوز: ${e.winRate}%',
                      style: GoogleFonts.cairo(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '🏆 ${e.wins} بولة',
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.greenAccent,
                    ),
                  ),
                  Text(
                    'مجموع: ${e.totalScore} ن',
                    style: GoogleFonts.cairo(fontSize: 11, color: Colors.amber.shade200),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
