import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../supabase/supabase_config.dart';

class MatchRecord {
  final String id;
  final DateTime date;
  final String? roomCode;
  final int targetScore;
  final int roundsPlayed;
  final String winnerName;
  final List<PlayerMatchResult> players;

  MatchRecord({
    required this.id,
    required this.date,
    this.roomCode,
    required this.targetScore,
    required this.roundsPlayed,
    required this.winnerName,
    required this.players,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'roomCode': roomCode,
        'targetScore': targetScore,
        'roundsPlayed': roundsPlayed,
        'winnerName': winnerName,
        'players': players.map((p) => p.toJson()).toList(),
      };

  factory MatchRecord.fromJson(Map<String, dynamic> json) => MatchRecord(
        id: json['id'] as String,
        date: DateTime.parse(json['date'] as String? ?? json['created_at'] as String),
        roomCode: (json['roomCode'] ?? json['room_code']) as String?,
        targetScore: ((json['targetScore'] ?? json['target_score']) as int?) ?? 100,
        roundsPlayed: ((json['roundsPlayed'] ?? json['rounds_played']) as int?) ?? 1,
        winnerName: ((json['winnerName'] ?? json['winner_name']) as String?) ?? 'فائز',
        players: (json['players'] as List? ?? [])
            .map((p) => PlayerMatchResult.fromJson(p as Map<String, dynamic>))
            .toList(),
      );
}

class PlayerMatchResult {
  final String? userId;
  final String name;
  final int score;
  final bool isWinner;

  PlayerMatchResult({
    this.userId,
    required this.name,
    required this.score,
    required this.isWinner,
  });

  Map<String, dynamic> toJson() => {
        if (userId != null) 'userId': userId,
        'name': name,
        'score': score,
        'isWinner': isWinner,
      };

  factory PlayerMatchResult.fromJson(Map<String, dynamic> json) => PlayerMatchResult(
        userId: json['userId'] as String?,
        name: json['name'] as String? ?? 'لاعب',
        score: (json['score'] as int?) ?? 0,
        isWinner: (json['isWinner'] as bool?) ?? false,
      );
}

class LeaderboardEntry {
  final String userId;
  final String displayName;
  final int gamesPlayed;
  final int wins;
  final int winRate;
  final int totalScore;

  const LeaderboardEntry({
    required this.userId,
    required this.displayName,
    required this.gamesPlayed,
    required this.wins,
    required this.winRate,
    required this.totalScore,
  });

  factory LeaderboardEntry.fromJson(Map<String, dynamic> json) => LeaderboardEntry(
        userId: json['userId'] as String? ?? '',
        displayName: json['displayName'] as String? ?? '',
        gamesPlayed: json['gamesPlayed'] as int? ?? 0,
        wins: json['wins'] as int? ?? 0,
        winRate: json['winRate'] as int? ?? 0,
        totalScore: json['totalScore'] as int? ?? 0,
      );
}

class ServerHistoryPayload {
  final List<MatchRecord> history;
  final List<LeaderboardEntry> leaderboard;

  const ServerHistoryPayload({
    required this.history,
    required this.leaderboard,
  });
}

class MatchHistoryManager {
  static const String _key = 'domino_match_history';

  static Future<void> saveMatch(MatchRecord record, {String? matchKey, bool syncToServer = false}) async {
    final prefs = await SharedPreferences.getInstance();
    final list = await getHistory();
    list.insert(0, record); // Most recent first

    final jsonList = list.map((r) => r.toJson()).toList();
    await prefs.setString(_key, jsonEncode(jsonList));

    if (syncToServer) {
      try {
        await SupabaseConfig.client.from('match_history').upsert({
          'id': record.id,
          'match_key': matchKey ?? record.id,
          'room_code': record.roomCode,
          'target_score': record.targetScore,
          'rounds_played': record.roundsPlayed,
          'winner_name': record.winnerName,
          'players': record.players.map((p) => p.toJson()).toList(),
          'created_at': record.date.toIso8601String(),
        }, onConflict: 'id');
      } catch (_) {}
    }
  }

  static Future<ServerHistoryPayload> getServerHistory({String? userId}) async {
    try {
      final res = await SupabaseConfig.client
          .from('match_history')
          .select()
          .order('created_at', ascending: false)
          .limit(100);

      final records = (res as List)
          .map((row) => MatchRecord.fromJson(row as Map<String, dynamic>))
          .toList();

      final usersRes = await SupabaseConfig.client.from('app_users').select('id, username, display_name');
      final usersMap = <String, String>{};
      for (final u in (usersRes as List)) {
        final id = u['id'] as String;
        final name = (u['display_name'] as String? ?? u['username'] as String? ?? id).trim();
        usersMap[id] = name;
      }

      final stats = <String, Map<String, dynamic>>{};
      for (final entry in usersMap.entries) {
        stats[entry.key] = {
          'userId': entry.key,
          'displayName': entry.value,
          'gamesPlayed': 0,
          'wins': 0,
          'totalScore': 0,
        };
      }

      for (final rec in records) {
        for (final p in rec.players) {
          final uid = p.userId;
          if (uid == null || uid.isEmpty) continue;
          if (!stats.containsKey(uid)) {
            stats[uid] = {
              'userId': uid,
              'displayName': p.name.isNotEmpty ? p.name : uid,
              'gamesPlayed': 0,
              'wins': 0,
              'totalScore': 0,
            };
          }
          final s = stats[uid]!;
          s['gamesPlayed'] = (s['gamesPlayed'] as int) + 1;
          if (p.isWinner) {
            s['wins'] = (s['wins'] as int) + 1;
          }
          s['totalScore'] = (s['totalScore'] as int) + p.score;
        }
      }

      final board = stats.values.map((s) {
        final gp = s['gamesPlayed'] as int;
        final wins = s['wins'] as int;
        final wr = gp > 0 ? ((wins / gp) * 100).round() : 0;
        return LeaderboardEntry(
          userId: s['userId'] as String,
          displayName: s['displayName'] as String,
          gamesPlayed: gp,
          wins: wins,
          winRate: wr,
          totalScore: s['totalScore'] as int,
        );
      }).toList();

      board.sort((a, b) {
        final c1 = b.wins.compareTo(a.wins);
        if (c1 != 0) return c1;
        final c2 = b.totalScore.compareTo(a.totalScore);
        if (c2 != 0) return c2;
        return b.gamesPlayed.compareTo(a.gamesPlayed);
      });

      final filteredRecords = (userId != null && userId.isNotEmpty)
          ? records.where((r) => r.players.any((p) => p.userId?.toLowerCase() == userId.toLowerCase())).toList()
          : records;

      return ServerHistoryPayload(history: filteredRecords, leaderboard: board);
    } catch (_) {
      final local = await getHistory();
      return ServerHistoryPayload(history: local, leaderboard: const []);
    }
  }

  static Future<List<MatchRecord>> getHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final str = prefs.getString(_key);
    if (str == null || str.isEmpty) return [];

    try {
      final decoded = jsonDecode(str) as List;
      return decoded.map((j) => MatchRecord.fromJson(j as Map<String, dynamic>)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
