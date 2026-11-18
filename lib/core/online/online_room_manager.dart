import 'dart:math';
import '../supabase/supabase_config.dart';

class OnlineRoomManager {
  static const int turnTimeoutMs = 60000;

  static Map<String, dynamic> generateAndDealTiles(int playerCount, {int? forcedStarter}) {
    final allTiles = <Map<String, dynamic>>[];
    int id = 0;
    for (int i = 0; i <= 6; i++) {
      for (int j = i; j <= 6; j++) {
        allTiles.add({'id': id++, 'head': i, 'tail': j});
      }
    }

    final rng = Random();
    // Fisher-Yates shuffle
    for (int i = allTiles.length - 1; i > 0; i--) {
      final j = rng.nextInt(i + 1);
      final tmp = allTiles[i];
      allTiles[i] = allTiles[j];
      allTiles[j] = tmp;
    }

    final hands = <List<Map<String, dynamic>>>[];
    for (int p = 0; p < playerCount; p++) {
      hands.add(allTiles.sublist(p * 7, (p + 1) * 7));
    }
    final boneyard = allTiles.sublist(playerCount * 7);

    int starter = forcedStarter ?? 0;
    if (forcedStarter == null) {
      int highestDouble = -1;
      for (int p = 0; p < playerCount; p++) {
        for (final t in hands[p]) {
          final h = t['head'] as int;
          final tl = t['tail'] as int;
          if (h == tl && h > highestDouble) {
            highestDouble = h;
            starter = p;
          }
        }
      }
    }

    return {
      'hands': hands,
      'boneyard': boneyard,
      'starter': starter,
      'playerCount': playerCount,
    };
  }

  static String generateRoomCode() {
    final rng = Random();
    return (10000 + rng.nextInt(90000)).toString();
  }

  static Future<Map<String, dynamic>?> createRoom({
    required String nickname,
    String? userId,
    required String playerToken,
    required int targetScore,
    int playerCount = 4,
  }) async {
    final code = generateRoomCode();
    final deal = generateAndDealTiles(playerCount);
    final now = DateTime.now().toUtc();

    final players = <Map<String, dynamic>>[];
    for (int i = 0; i < playerCount; i++) {
      players.add({
        'name': i == 0 ? nickname : 'لاعب ${i + 1}',
        'userId': i == 0 ? userId : null,
        'token': i == 0 ? playerToken : null,
        'joined': i == 0,
        'isBot': false,
        'lastSeen': i == 0 ? now.millisecondsSinceEpoch : null,
      });
    }

    final roomRow = {
      'code': code,
      'creator_token': playerToken,
      'target_score': targetScore,
      'round_number': 1,
      'match_seq': 1,
      'started': false,
      'players': players,
      'watchers': <Map<String, dynamic>>[],
      'deal': deal,
      'actions': <Map<String, dynamic>>[],
      'next_round_votes': <String, dynamic>{},
      'turn_started_at': null,
      'updated_at': now.toIso8601String(),
      'created_at': now.toIso8601String(),
    };

    await SupabaseConfig.client.from('game_rooms').insert(roomRow);

    return {
      'ok': true,
      'roomCode': code,
      'playerIndex': 0,
      'targetScore': targetScore,
      'matchSeq': 1,
      'started': false,
      'deal': deal,
      'initialDeal': deal,
      'players': players,
      'watchers': [],
    };
  }

  static Future<Map<String, dynamic>> joinRoom({
    required String code,
    required String nickname,
    String? userId,
    required String playerToken,
    bool preferWatcher = false,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) {
      return {'ok': false, 'message': 'الغرفة غير موجودة'};
    }

    final now = DateTime.now().toUtc();
    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final watchers = List<Map<String, dynamic>>.from(
      (row['watchers'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final actions = List<Map<String, dynamic>>.from(row['actions'] as List? ?? []);
    final deal = row['deal'] as Map<String, dynamic>? ?? {};
    final targetScore = row['target_score'] as int? ?? 31;
    final matchSeq = row['match_seq'] as int? ?? 1;
    final started = row['started'] as bool? ?? false;

    // Check if player already seated
    int seatedIdx = players.indexWhere((p) => p['token'] == playerToken);

    if (seatedIdx != -1) {
      // Reconnecting to existing seat
      players[seatedIdx]['lastSeen'] = now.millisecondsSinceEpoch;
      if (nickname.isNotEmpty) players[seatedIdx]['name'] = nickname;
      if (userId != null) players[seatedIdx]['userId'] = userId;
      players[seatedIdx]['joined'] = true;

      await SupabaseConfig.client.from('game_rooms').update({
        'players': players,
        'updated_at': now.toIso8601String(),
      }).eq('code', cleanCode);

      final joinedCount = players.where((p) => p['joined'] == true).length;
      return {
        'ok': true,
        'roomCode': cleanCode,
        'role': 'player',
        'playerIndex': seatedIdx,
        'targetScore': targetScore,
        'matchSeq': matchSeq,
        'started': started,
        'turnRemainingMs': _calcTurnRemainingMs(row['turn_started_at']),
        'actions': actions,
        'players': players,
        'watchers': watchers,
        'deal': deal,
        'initialDeal': deal,
        'joinedCount': joinedCount,
      };
    }

    if (!preferWatcher) {
      // Find open seat or replacement seat
      int openIdx = players.indexWhere((p) => p['joined'] != true && p['isBot'] != true);
      if (openIdx == -1 && !started) {
        // Can replace a bot if game hasn't started
        openIdx = players.indexWhere((p) => p['isBot'] == true);
      }

      if (openIdx != -1) {
        players[openIdx] = {
          'name': nickname.isNotEmpty ? nickname : 'لاعب ${openIdx + 1}',
          'userId': userId,
          'token': playerToken,
          'joined': true,
          'isBot': false,
          'lastSeen': now.millisecondsSinceEpoch,
        };

        // Remove from watchers if present
        watchers.removeWhere((w) => w['token'] == playerToken || w['id'] == playerToken);

        final joinedCount = players.where((p) => p['joined'] == true).length;
        await SupabaseConfig.client.from('game_rooms').update({
          'players': players,
          'watchers': watchers,
          'updated_at': now.toIso8601String(),
        }).eq('code', cleanCode);

        return {
          'ok': true,
          'roomCode': cleanCode,
          'role': 'player',
          'playerIndex': openIdx,
          'targetScore': targetScore,
          'matchSeq': matchSeq,
          'started': started,
          'turnRemainingMs': _calcTurnRemainingMs(row['turn_started_at']),
          'actions': actions,
          'players': players,
          'watchers': watchers,
          'deal': deal,
          'initialDeal': deal,
          'joinedCount': joinedCount,
        };
      }
    }

    // Join as watcher
    final existingWatcherIdx = watchers.indexWhere((w) => w['token'] == playerToken || w['id'] == playerToken);
    if (existingWatcherIdx != -1) {
      watchers[existingWatcherIdx]['lastSeen'] = now.millisecondsSinceEpoch;
      if (nickname.isNotEmpty) watchers[existingWatcherIdx]['name'] = nickname;
    } else {
      watchers.add({
        'id': playerToken,
        'token': playerToken,
        'name': nickname.isNotEmpty ? nickname : 'مشاهد',
        'userId': userId,
        'joinedAt': now.millisecondsSinceEpoch,
        'lastSeen': now.millisecondsSinceEpoch,
      });
    }

    await SupabaseConfig.client.from('game_rooms').update({
      'watchers': watchers,
      'updated_at': now.toIso8601String(),
    }).eq('code', cleanCode);

    final joinedCount = players.where((p) => p['joined'] == true).length;
    return {
      'ok': true,
      'roomCode': cleanCode,
      'role': 'watcher',
      'playerIndex': -1,
      'targetScore': targetScore,
      'matchSeq': matchSeq,
      'started': started,
      'turnRemainingMs': _calcTurnRemainingMs(row['turn_started_at']),
      'actions': actions,
      'players': players,
      'watchers': watchers,
      'deal': deal,
      'initialDeal': deal,
      'joinedCount': joinedCount,
    };
  }

  static Future<Map<String, dynamic>?> syncRoom({
    required String code,
    required String playerToken,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return null;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final watchers = List<Map<String, dynamic>>.from(
      (row['watchers'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final actions = List<Map<String, dynamic>>.from(row['actions'] as List? ?? []);
    final deal = row['deal'] as Map<String, dynamic>? ?? {};
    final nextRoundVotes = (row['next_round_votes'] as Map? ?? {}).cast<String, dynamic>();

    final myIdx = players.indexWhere((p) => p['token'] == playerToken);
    final isWatcher = myIdx == -1;
    final isCreator = (row['creator_token'] == playerToken) || (myIdx == 0);
    final joinedCount = players.where((p) => p['joined'] == true).length;

    return {
      'ok': true,
      'roomCode': cleanCode,
      'targetScore': row['target_score'] as int? ?? 31,
      'matchSeq': row['match_seq'] as int? ?? 1,
      'roundNumber': row['round_number'] as int? ?? 1,
      'started': row['started'] as bool? ?? false,
      'joinedCount': joinedCount,
      'isCreator': isCreator,
      'isKicked': false,
      'myRole': isWatcher ? 'watcher' : 'player',
      'myPlayerIndex': myIdx,
      'turnRemainingMs': _calcTurnRemainingMs(row['turn_started_at']),
      'players': players,
      'watchers': watchers,
      'actions': actions,
      'deal': deal,
      'initialDeal': deal,
      'nextRoundVotes': nextRoundVotes,
    };
  }

  static Future<void> sendAction({
    required String code,
    required Map<String, dynamic> action,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select('actions')
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final actions = List<Map<String, dynamic>>.from(row['actions'] as List? ?? []);
    final now = DateTime.now().toUtc();
    final enrichedAction = {
      ...action,
      'id': actions.length,
      'timestamp': now.millisecondsSinceEpoch,
    };
    actions.add(enrichedAction);

    await SupabaseConfig.client.from('game_rooms').update({
      'actions': actions,
      'turn_started_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    }).eq('code', cleanCode);
  }

  static Future<void> voteReadyForNextRound({
    required String code,
    required String playerToken,
    required int playerIndex,
    required int winnerIndex,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final rawVotes = Map<String, dynamic>.from(row['next_round_votes'] as Map? ?? {});
    rawVotes[playerIndex.toString()] = true;

    // Auto-approve all bots
    for (int i = 0; i < players.length; i++) {
      if (players[i]['isBot'] == true) {
        rawVotes[i.toString()] = true;
      }
    }

    // Check if all joined seated players approved
    final joinedIndices = <int>[];
    for (int i = 0; i < players.length; i++) {
      if (players[i]['joined'] == true) {
        joinedIndices.add(i);
      }
    }

    final allApproved = joinedIndices.isNotEmpty && joinedIndices.every((idx) => rawVotes[idx.toString()] == true);

    if (allApproved) {
      final currentRound = row['round_number'] as int? ?? 1;
      final newRound = currentRound + 1;
      final newDeal = generateAndDealTiles(players.length, forcedStarter: winnerIndex);
      final actions = List<Map<String, dynamic>>.from(row['actions'] as List? ?? []);
      final now = DateTime.now().toUtc();

      final nextRoundAction = {
        'id': actions.length,
        'actionType': 'next_round',
        'playerIndex': winnerIndex,
        'roundNumber': newRound,
        'deal': newDeal,
        'timestamp': now.millisecondsSinceEpoch,
      };
      actions.add(nextRoundAction);

      // If next round starter is a bot, play highest double immediately
      if (winnerIndex >= 0 && winnerIndex < players.length && players[winnerIndex]['isBot'] == true) {
        final hands = newDeal['hands'] as List;
        final botHand = List<Map<String, dynamic>>.from(hands[winnerIndex] as List);
        Map<String, dynamic>? bestTile;
        int bestPip = -1;
        for (final t in botHand) {
          final h = t['head'] as int;
          final tl = t['tail'] as int;
          if (h == tl && (h + tl) > bestPip) {
            bestPip = h + tl;
            bestTile = t;
          }
        }

        if (bestTile != null) {
          actions.add({
            'id': actions.length,
            'actionType': 'play',
            'playerIndex': winnerIndex,
            'tileId': bestTile['id'],
            'head': bestTile['head'],
            'tail': bestTile['tail'],
            'targetDirection': null,
            'autoPlayed': true,
            'timestamp': now.millisecondsSinceEpoch,
          });
        } else {
          actions.add({
            'id': actions.length,
            'actionType': 'pass',
            'playerIndex': winnerIndex,
            'autoPlayed': true,
            'timestamp': now.millisecondsSinceEpoch,
          });
        }
      }

      await SupabaseConfig.client.from('game_rooms').update({
        'round_number': newRound,
        'deal': newDeal,
        'started': true,
        'actions': actions,
        'next_round_votes': <String, dynamic>{},
        'turn_started_at': now.toIso8601String(),
        'updated_at': now.toIso8601String(),
      }).eq('code', cleanCode);
    } else {
      await SupabaseConfig.client.from('game_rooms').update({
        'next_round_votes': rawVotes,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('code', cleanCode);
    }
  }

  static Future<void> kickPlayer({
    required String code,
    required String adminToken,
    required int targetIndex,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;
    if (row['creator_token'] != adminToken) return;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );

    if (targetIndex >= 0 && targetIndex < players.length) {
      players[targetIndex] = {
        'name': 'بوت (${targetIndex + 1}) 🤖',
        'userId': null,
        'token': null,
        'joined': true,
        'isBot': true,
        'lastSeen': DateTime.now().toUtc().millisecondsSinceEpoch,
      };

      await SupabaseConfig.client.from('game_rooms').update({
        'players': players,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('code', cleanCode);
    }
  }

  static Future<void> startOnlineGameEarly({required String code}) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );

    for (int i = 0; i < players.length; i++) {
      if (players[i]['joined'] != true) {
        players[i] = {
          'name': 'بوت (${i + 1}) 🤖',
          'userId': null,
          'token': null,
          'joined': true,
          'isBot': true,
          'lastSeen': DateTime.now().toUtc().millisecondsSinceEpoch,
        };
      }
    }

    final now = DateTime.now().toUtc();
    await SupabaseConfig.client.from('game_rooms').update({
      'players': players,
      'started': true,
      'turn_started_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    }).eq('code', cleanCode);
  }

  static Future<void> vacateSeat({
    required String code,
    required int slotIndex,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );

    if (slotIndex >= 0 && slotIndex < players.length) {
      players[slotIndex] = {
        'name': 'مقعد متاح ${slotIndex + 1}',
        'userId': null,
        'token': null,
        'joined': false,
        'isBot': false,
        'lastSeen': null,
      };

      await SupabaseConfig.client.from('game_rooms').update({
        'players': players,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('code', cleanCode);
    }
  }

  static Future<void> promoteWatcher({
    required String code,
    required int slotIndex,
    String? watcherId,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final watchers = List<Map<String, dynamic>>.from(
      (row['watchers'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );

    int watcherIdx = -1;
    if (watcherId != null) {
      watcherIdx = watchers.indexWhere((w) => w['id'] == watcherId || w['token'] == watcherId);
    } else if (watchers.isNotEmpty) {
      watcherIdx = 0;
    }

    if (watcherIdx != -1 && slotIndex >= 0 && slotIndex < players.length) {
      final watcher = watchers.removeAt(watcherIdx);
      players[slotIndex] = {
        'name': watcher['name'] ?? 'لاعب ${slotIndex + 1}',
        'userId': watcher['userId'],
        'token': watcher['token'] ?? watcher['id'],
        'isBot': false,
        'joined': true,
        'lastSeen': DateTime.now().toUtc().millisecondsSinceEpoch,
      };

      await SupabaseConfig.client.from('game_rooms').update({
        'players': players,
        'watchers': watchers,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }).eq('code', cleanCode);
    }
  }

  static Future<void> leaveRoom({
    required String code,
    required String playerToken,
    int? playerIndex,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final players = List<Map<String, dynamic>>.from(
      (row['players'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );
    final watchers = List<Map<String, dynamic>>.from(
      (row['watchers'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)),
    );

    watchers.removeWhere((w) => w['token'] == playerToken || w['id'] == playerToken);

    int targetIdx = playerIndex ?? -1;
    if (targetIdx == -1) {
      targetIdx = players.indexWhere((p) => p['token'] == playerToken);
    }

    if (targetIdx >= 0 && targetIdx < players.length) {
      players[targetIdx]['joined'] = false;
      players[targetIdx]['token'] = null;
      players[targetIdx]['lastSeen'] = null;
      players[targetIdx]['name'] = 'مقعد متاح ${targetIdx + 1}';
    }

    await SupabaseConfig.client.from('game_rooms').update({
      'players': players,
      'watchers': watchers,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('code', cleanCode);
  }

  static Future<void> updateTargetScore({
    required String code,
    required int targetScore,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    await SupabaseConfig.client.from('game_rooms').update({
      'target_score': targetScore,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('code', cleanCode);
  }

  static Future<void> newMatch({
    required String code,
    required int targetScore,
  }) async {
    final cleanCode = code.trim().toUpperCase();
    final row = await SupabaseConfig.client
        .from('game_rooms')
        .select()
        .eq('code', cleanCode)
        .maybeSingle();

    if (row == null) return;

    final playerCount = (row['players'] as List? ?? []).length;
    final newDeal = generateAndDealTiles(playerCount > 0 ? playerCount : 4);
    final now = DateTime.now().toUtc();
    final matchSeq = (row['match_seq'] as int? ?? 1) + 1;

    await SupabaseConfig.client.from('game_rooms').update({
      'target_score': targetScore,
      'match_seq': matchSeq,
      'round_number': 1,
      'deal': newDeal,
      'actions': <Map<String, dynamic>>[],
      'next_round_votes': <String, dynamic>{},
      'turn_started_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    }).eq('code', cleanCode);
  }

  static int _calcTurnRemainingMs(dynamic turnStartedAt) {
    if (turnStartedAt == null) return turnTimeoutMs;
    try {
      final started = DateTime.parse(turnStartedAt.toString());
      final elapsed = DateTime.now().toUtc().difference(started).inMilliseconds;
      final rem = turnTimeoutMs - elapsed;
      return rem < 0 ? 0 : rem;
    } catch (_) {
      return turnTimeoutMs;
    }
  }
}
