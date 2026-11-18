import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/auth/auth_manager.dart';
import '../../../core/history/match_history_dialog.dart';
import '../../../core/history/match_history_manager.dart';
import '../../../core/online/online_room_manager.dart';
import '../../../core/utils/vibration_helper.dart';
import '../../game_engine/ai/heuristic_bot.dart';
import '../../game_engine/domain/game_state.dart';
import '../../game_engine/domain/models/direction.dart';
import '../../game_engine/domain/models/domino_tile.dart';
import '../../game_engine/domain/models/open_end.dart';
import '../../game_engine/domain/models/player.dart';
import '../../game_engine/domain/rules/game_controller.dart';
import '../../game_engine/domain/rules/scoring_calculator.dart';
import 'widgets/board_canvas_widget.dart';
import 'widgets/domino_tile_widget.dart';
import 'widgets/scoreboard_nawta.dart';

enum GameMode {
  onlineMultiplayer, // كل لاعب من جهازه الخاص (أونلاين / واي فاي)
  passAndPlay,       // على نفس الجهاز بالتبادل (٤ لاعبين)
  vsComputer,        // ضد الكمبيوتر
}

class GameScreen extends StatefulWidget {
  final int targetScore;

  const GameScreen({
    super.key,
    this.targetScore = 31,
  });

  @override
  State<GameScreen> createState() => _GameScreenState();
}

class _GameScreenState extends State<GameScreen> {
  late GameController _controller;
  DominoTile? _selectedTile;
  bool _isBotThinking = false;
  GameMode _gameMode = GameMode.onlineMultiplayer;
  late int _targetScore;

  // Online Multiplayer & Watchers State
  String? _onlineRoomCode;
  int _onlinePlayerIndex = 0; // 0..3 when player, -1 when watcher
  bool _isWatcher = false;
  String? _playerToken;
  int _onlineMatchSeq = 1;
  bool _onlineGameStarted = false;
  List<Map<String, dynamic>> _onlinePlayersMeta = [];
  List<Map<String, dynamic>> _watchersMeta = [];
  Timer? _syncTimer;
  Timer? _turnTickTimer;
  int _processedActionsCount = 0;
  bool _isWaitingForOpponents = false;
  int _joinedPlayersCount = 1;
  bool _hasSavedThisMatch = false;
  bool _isRequestingNextRound = false;

  // 1-Minute Turn Timer State
  int _turnSecondsLeft = 60;
  int _onlineTurnRemainingMs = 60000;
  DateTime? _onlineZeroSince;
  DateTime? _localTurnStartedAt;
  bool _isAutoActing = false;
  bool _showStartLobby = true;
  AuthUser? _currentUser;
  bool _isRegisterMode = false;
  bool _isAuthSubmitting = false;
  final TextEditingController _lobbyNameCtrl = TextEditingController();
  final TextEditingController _lobbyCodeCtrl = TextEditingController();
  final TextEditingController _lobbyTargetCtrl = TextEditingController(text: '31');
  final TextEditingController _authUserCtrl = TextEditingController();
  final TextEditingController _authPinCtrl = TextEditingController();
  final TextEditingController _authDisplayCtrl = TextEditingController();
  int _lobbyTargetScore = 31;
  int _lastActivePlayerForVibration = -1;
  Timer? _onlineBotTimer;
  List<bool> _previousBots = [];
  Map<int, bool> _nextRoundVotes = {};
  bool _isReadyForNextRound = false;
  bool _isRoomCreator = false;
  bool _isKickedEvicted = false;

  @override
  void initState() {
    super.initState();
    _targetScore = widget.targetScore;
    _lobbyTargetScore = widget.targetScore;
    _lobbyTargetCtrl.text = '${widget.targetScore}';
    _controller = GameController();
    _startMatch();
    _startTurnTickTimer();
    _loadSavedTargetScore();
    _restoreAuthAndReconnect();
  }

  Future<void> _restoreAuthAndReconnect() async {
    final user = await AuthManager.restoreSession();
    final nick = await _getSavedNickname();
    if (!mounted) return;
    setState(() {
      _currentUser = user;
      if (user != null) {
        _lobbyNameCtrl.text = user.displayName;
      } else if (nick != null && nick.isNotEmpty && _lobbyNameCtrl.text.isEmpty) {
        _lobbyNameCtrl.text = nick;
      }
    });
    await _checkAutoReconnect();
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _turnTickTimer?.cancel();
    _onlineBotTimer?.cancel();
    _lobbyNameCtrl.dispose();
    _lobbyCodeCtrl.dispose();
    _lobbyTargetCtrl.dispose();
    _authUserCtrl.dispose();
    _authPinCtrl.dispose();
    _authDisplayCtrl.dispose();
    super.dispose();
  }

  Future<String> _getOrCreatePlayerToken() async {
    if (_playerToken != null && _playerToken!.isNotEmpty) return _playerToken!;
    final prefs = await SharedPreferences.getInstance();
    String? token = prefs.getString('domino_player_token');
    if (token == null || token.isEmpty) {
      token = 'tok_${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';
      await prefs.setString('domino_player_token', token);
    }
    _playerToken = token;
    return token;
  }

  Future<void> _loadSavedTargetScore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('domino_target_score');
    if (saved != null && saved >= 1 && mounted && _onlineRoomCode == null) {
      setState(() {
        _targetScore = saved;
        _lobbyTargetScore = saved;
        _lobbyTargetCtrl.text = '$saved';
        _controller.setTargetScore(saved);
      });
    }
  }

  Future<void> _saveTargetScore(int score) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('domino_target_score', score);
  }

  Future<String?> _getSavedNickname() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('domino_user_nickname');
  }

  Future<void> _saveNickname(String nickname) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('domino_user_nickname', nickname);
  }

  Future<void> _saveActiveRoom(String roomCode, int playerIndex) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('domino_active_room_code', roomCode);
    await prefs.setInt('domino_player_index', playerIndex);
  }

  Future<void> _clearActiveRoom() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('domino_active_room_code');
    await prefs.remove('domino_player_index');
  }

  Future<void> _checkAutoReconnect() async {
    final prefs = await SharedPreferences.getInstance();
    final savedRoom = prefs.getString('domino_active_room_code');
    if (savedRoom != null && savedRoom.isNotEmpty) {
      final savedNickname = prefs.getString('domino_user_nickname') ?? '';
      await _joinOnlineRoom(savedRoom, nickname: savedNickname, isAutoReconnect: true);
    }
  }

  Future<void> _leaveRoom() async {
    final roomCode = _onlineRoomCode;
    final token = await _getOrCreatePlayerToken();
    final playerIdx = _onlinePlayerIndex;
    if (roomCode != null) {
      try {
        await OnlineRoomManager.leaveRoom(
          code: roomCode,
          playerToken: token,
          playerIndex: playerIdx,
        );
      } catch (_) {}
    }

    await _clearActiveRoom();
    setState(() {
      _syncTimer?.cancel();
      _onlineRoomCode = null;
      _onlinePlayerIndex = 0;
      _isWatcher = false;
      _onlineGameStarted = false;
      _isWaitingForOpponents = false;
      _onlinePlayersMeta = [];
      _watchersMeta = [];
      _processedActionsCount = 0;
      _showStartLobby = true;
      _startMatch();
    });
    _showToast('تمت مغادرة الغرفة وإتاحة مقعدك للاعب آخر');
  }

  void _resetLocalTurnTimer() {
    _localTurnStartedAt = DateTime.now();
    _turnSecondsLeft = 60;
    _onlineTurnRemainingMs = 60000;
    _onlineZeroSince = null;
    _isAutoActing = false;
  }

  void _startTurnTickTimer() {
    _turnTickTimer?.cancel();
    _turnTickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _showStartLobby) return;
      final state = _controller.state;
      if (state.isRoundOver || state.isGameOver) {
        _onlineZeroSince = null;
        return;
      }

      if (_gameMode == GameMode.onlineMultiplayer && _onlineRoomCode != null) {
        if (!_onlineGameStarted || _isWaitingForOpponents) {
          if (_turnSecondsLeft != 60) setState(() => _turnSecondsLeft = 60);
          return;
        }
        final nextMs = max(0, _onlineTurnRemainingMs - 1000);
        _onlineTurnRemainingMs = nextMs;
        final nextSec = (nextMs / 1000).ceil();
        if (nextSec != _turnSecondsLeft) {
          setState(() => _turnSecondsLeft = nextSec);
        }

        final activeIdx = state.activePlayerIndex;
        final isBot = (_onlinePlayersMeta.length > activeIdx && _onlinePlayersMeta[activeIdx]['isBot'] == true) ||
            state.players[activeIdx].isAi;
        if (isBot) {
          _checkOnlineBotTurn();
          // Unbreakable fallback: if a bot turn stays pending for more than 2s without moving
          if (_turnSecondsLeft <= 58 && !_isWatcher && !_isAutoActing) {
            _performOnlineBotMove(activeIdx);
          }
        }

        if (nextMs <= 0 && !_isWatcher && !_isAutoActing) {
          _onlineZeroSince ??= DateTime.now();
          final activeIdx = state.activePlayerIndex;
          final zeroElapsedMs = DateTime.now().difference(_onlineZeroSince!).inMilliseconds;
          final backupOffset = ((_onlinePlayerIndex - activeIdx + 4) % 4) - 1;
          final shouldTrigger = (activeIdx == _onlinePlayerIndex) ||
              (zeroElapsedMs >= 2000 + backupOffset * 1000);
          if (shouldTrigger) {
            _performOnlineAutoMove(activeIdx);
          }
        }
        return;
      }

      // Local / Pass-and-Play / vsComputer 60-second timer
      if (_isBotThinking) return;
      _localTurnStartedAt ??= DateTime.now();
      final elapsed = DateTime.now().difference(_localTurnStartedAt!).inSeconds;
      final remaining = max(0, 60 - elapsed);
      if (remaining != _turnSecondsLeft) {
        setState(() => _turnSecondsLeft = remaining);
      }
      if (remaining <= 0 && !_isAutoActing) {
        _performLocalAutoMove(state.activePlayerIndex);
      }
    });
  }

  Map<String, dynamic> _chooseAutoActionForPlayer(int playerIdx) {
    final state = _controller.state;
    final hand = state.players[playerIdx].hand;
    if (state.board.isEmpty) {
      final doubles = hand.where((t) => t.isDouble).toList();
      if (doubles.isNotEmpty) {
        doubles.sort((a, b) => b.pipSum.compareTo(a.pipSum));
        return {'actionType': 'play', 'tile': doubles.first, 'targetEnd': null};
      }
      return {'actionType': 'pass'};
    }

    for (final tile in hand) {
      final ends = state.board.findLegalPlacements(tile);
      if (ends.isNotEmpty) {
        return {'actionType': 'play', 'tile': tile, 'targetEnd': ends.first};
      }
    }
    return {'actionType': 'pass'};
  }

  void _performLocalAutoMove(int activeIdx) {
    if (_isAutoActing || _controller.state.isRoundOver) return;
    _isAutoActing = true;
    final choice = _chooseAutoActionForPlayer(activeIdx);
    setState(() {
      if (choice['actionType'] == 'play') {
        _controller.playTile(
          playerIndex: activeIdx,
          tile: choice['tile'] as DominoTile,
          targetEnd: choice['targetEnd'] as OpenEnd?,
        );
      } else {
        _controller.passTurn(activeIdx);
      }
      _selectedTile = null;
      _resetLocalTurnTimer();
    });
    _checkSaveMatchRecord();
    if (_gameMode == GameMode.vsComputer) _checkBotTurn();
    _checkAndTriggerTurnVibration();
    _showToast('انتهى الوقت (٦٠ث) — تم لعب حركة تلقائية');
  }

  Future<void> _performOnlineAutoMove(int activeIdx) async {
    if (_isAutoActing || _onlineRoomCode == null || _isWatcher || _controller.state.isRoundOver) return;
    _isAutoActing = true;
    final choice = _chooseAutoActionForPlayer(activeIdx);
    try {
      await OnlineRoomManager.sendAction(
        code: _onlineRoomCode!,
        action: {
          'roomCode': _onlineRoomCode,
          'playerIndex': activeIdx,
          'actionType': choice['actionType'],
          'tileId': (choice['tile'] as DominoTile?)?.id,
          'targetDirection': (choice['targetEnd'] as OpenEnd?)?.attachDirection.name,
          'targetBranch': (choice['targetEnd'] as OpenEnd?)?.branch.name,
          'autoPlayed': true,
        },
      );
      await _syncRoom();
    } catch (_) {
    } finally {
      _isAutoActing = false;
    }
  }

  void _checkAndTriggerTurnVibration() {
    if (!mounted || _showStartLobby) return;
    final state = _controller.state;
    if (state.isRoundOver || state.isGameOver) {
      _lastActivePlayerForVibration = -1;
      return;
    }

    final currentIdx = state.activePlayerIndex;
    final bool isMyTurn;
    switch (_gameMode) {
      case GameMode.onlineMultiplayer:
        isMyTurn = _onlineRoomCode != null &&
            _onlineGameStarted &&
            !_isWaitingForOpponents &&
            !_isWatcher &&
            currentIdx == _onlinePlayerIndex;
        break;
      case GameMode.vsComputer:
        isMyTurn = currentIdx == 0 && !_isBotThinking;
        break;
      case GameMode.passAndPlay:
        isMyTurn = true;
        break;
    }

    if (isMyTurn && _lastActivePlayerForVibration != currentIdx) {
      VibrationHelper.vibrateTurnArrival();
    }
    _lastActivePlayerForVibration = currentIdx;
  }

  void _startMatch() {
    _hasSavedThisMatch = false;
    _resetLocalTurnTimer();
    setState(() {
      _selectedTile = null;
      _isBotThinking = false;
      _controller.startMatch(
        playerCount: 4,
        playerNames: ['لاعب ١', 'لاعب ٢', 'لاعب ٣', 'لاعب ٤'],
        vsAi: _gameMode == GameMode.vsComputer,
        targetScore: _targetScore,
      );
    });

    if (_gameMode == GameMode.vsComputer) {
      _checkBotTurn();
    }
    _checkAndTriggerTurnVibration();
  }

  List<DominoTile> _parseTiles(List jsonList) {
    return jsonList
        .map((j) => DominoTile(j['head'] as int, j['tail'] as int, id: j['id'] as int))
        .toList();
  }

  void _setupDeal(Map<String, dynamic> deal, {List<String>? playerNames, List<bool>? isAiList, int? targetScore}) {
    _hasSavedThisMatch = false;
    final handsRaw = deal['hands'] as List? ?? [];
    final hands = handsRaw.map((h) => _parseTiles(h as List)).toList();
    final boneyard = _parseTiles(deal['boneyard'] as List? ?? []);
    final starter = deal['starter'] as int? ?? 0;
    final names = playerNames ?? ['لاعب ١', 'لاعب ٢', 'لاعب ٣', 'لاعب ٤'];
    final effectiveTarget = targetScore ?? _targetScore;
    _targetScore = effectiveTarget;

    _controller.startMatchWithDeal(
      hands: hands,
      boneyard: boneyard,
      startingPlayerIndex: starter,
      playerNames: names,
      isAiList: isAiList,
      targetScore: effectiveTarget,
    );
    _checkAndTriggerTurnVibration();
    _checkOnlineBotTurn();
  }

  Future<void> _createOnlineRoom(String nickname, {int? targetScore}) async {
    try {
      final token = await _getOrCreatePlayerToken();
      if (nickname.isNotEmpty) {
        await _saveNickname(nickname);
      } else {
        nickname = (await _getSavedNickname()) ?? 'لاعب ١';
      }
      final desiredTarget = targetScore ?? _targetScore;
      await _saveTargetScore(desiredTarget);

      if (nickname.isEmpty && _currentUser != null) {
        nickname = _currentUser!.displayName;
      }
      final data = await OnlineRoomManager.createRoom(
        nickname: nickname,
        userId: _currentUser?.userId,
        playerToken: token,
        targetScore: desiredTarget,
        playerCount: 4,
      );
      if (data != null && data['ok'] == true) {
        final roomCode = data['roomCode'] as String;
        final roomTarget = (data['targetScore'] as int?) ?? desiredTarget;
        final matchSeq = (data['matchSeq'] as int?) ?? 1;
        final playersRaw = data['players'] as List? ?? [];
        final playerNames = playersRaw.map((p) => (p['name'] as String?) ?? '').toList();

        await _saveActiveRoom(roomCode, 0);

        setState(() {
          _onlineRoomCode = roomCode;
          _onlinePlayerIndex = 0;
          _isWatcher = false;
          _showStartLobby = false;
          _onlineMatchSeq = matchSeq;
          _onlineGameStarted = (data['started'] as bool?) ?? false;
          _onlinePlayersMeta = playersRaw.cast<Map<String, dynamic>>();
          _watchersMeta = (data['watchers'] as List? ?? []).cast<Map<String, dynamic>>();
          _isWaitingForOpponents = true;
          _joinedPlayersCount = 1;
          _processedActionsCount = 0;
          _selectedTile = null;
          _resetLocalTurnTimer();
          final isAiList = playersRaw.map((p) => p['isBot'] == true).toList();
          _previousBots = isAiList;
          _setupDeal(
            (data['initialDeal'] ?? data['deal']) as Map<String, dynamic>,
            playerNames: playerNames,
            isAiList: isAiList,
            targetScore: roomTarget,
          );
        });
        _startSyncPolling();
      }
    } catch (e) {
      _showToast('تعذر إنشاء الغرفة: تأكد من الاتصال بـ Supabase');
    }
  }

  Future<void> _joinOnlineRoom(
    String code, {
    String nickname = '',
    bool isAutoReconnect = false,
    bool preferWatcher = false,
  }) async {
    try {
      final token = await _getOrCreatePlayerToken();
      if (nickname.isNotEmpty) {
        await _saveNickname(nickname);
      } else {
        nickname = (await _getSavedNickname()) ?? '';
      }

      if (nickname.isEmpty && _currentUser != null) {
        nickname = _currentUser!.displayName;
      }
      final data = await OnlineRoomManager.joinRoom(
        code: code,
        nickname: nickname,
        userId: _currentUser?.userId,
        playerToken: token,
        preferWatcher: preferWatcher,
      );

      if (data['ok'] == true) {
        final roomCode = data['roomCode'] as String;
        final role = (data['role'] as String?) ?? 'player';
        final assignedIdx = data['playerIndex'] as int? ?? -1;
        final roomTarget = (data['targetScore'] as int?) ?? _targetScore;
        final matchSeq = (data['matchSeq'] as int?) ?? 1;
        final started = (data['started'] as bool?) ?? false;
        final remMs = (data['turnRemainingMs'] as int?) ?? 60000;
        final actions = data['actions'] as List? ?? [];
        final playersRaw = data['players'] as List? ?? [];
        final watchersRaw = data['watchers'] as List? ?? [];
        final playerNames = playersRaw.map((p) => (p['name'] as String?) ?? '').toList();
        final joinedCount = data['joinedCount'] as int? ?? 1;

        await _saveActiveRoom(roomCode, assignedIdx);

        setState(() {
          _onlineRoomCode = roomCode;
          _isWatcher = role == 'watcher' || assignedIdx < 0;
          _onlinePlayerIndex = _isWatcher ? -1 : assignedIdx;
          _showStartLobby = false;
          _onlineMatchSeq = matchSeq;
          _onlineGameStarted = started;
          _onlineTurnRemainingMs = remMs;
          _turnSecondsLeft = (remMs / 1000).ceil();
          _onlineZeroSince = remMs <= 0 ? DateTime.now() : null;
          _onlinePlayersMeta = playersRaw.cast<Map<String, dynamic>>();
          _watchersMeta = watchersRaw.cast<Map<String, dynamic>>();
          _joinedPlayersCount = joinedCount;
          _isWaitingForOpponents = !_isWatcher && !started && joinedCount < 4 && actions.isEmpty;
          _processedActionsCount = 0;
          _selectedTile = null;
          final isAiList = playersRaw.map((p) => p['isBot'] == true).toList();
          _previousBots = isAiList;
          _setupDeal(
            (data['initialDeal'] ?? data['deal']) as Map<String, dynamic>,
            playerNames: playerNames,
            isAiList: isAiList,
            targetScore: roomTarget,
          );

          // Replay all actions from round 1 to restore exact current progress!
          for (final act in actions) {
            _applyActionInternal(act as Map<String, dynamic>);
            _processedActionsCount++;
          }
        });

        _startSyncPolling();
        if (isAutoReconnect) {
          _showToast('تم استعادة الجلسة ومتابعة اللعب في الغرفة #$roomCode');
        } else if (_isWatcher) {
          _showToast('دخلت الغرفة #$roomCode بوضع المشاهدة 👁️');
        }
      } else {
        if (isAutoReconnect) {
          await _clearActiveRoom();
        } else {
          _showToast(data['message'] ?? 'الغرفة غير موجودة أو مكتملة');
        }
      }
    } catch (e) {
      if (!isAutoReconnect) {
        _showToast('تعذر الانضمام للغرفة');
      }
    }
  }

  void _startSyncPolling() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(milliseconds: 600), (_) => _syncRoom());
  }

  Future<void> _syncRoom() async {
    if (_onlineRoomCode == null) return;
    try {
      final token = _playerToken ?? '';
      final data = await OnlineRoomManager.syncRoom(code: _onlineRoomCode!, playerToken: token);
      if (data != null && data['ok'] == true) {

        // Check if admin kicked this player
        if (data['isKicked'] == true && !_isKickedEvicted) {
          _isKickedEvicted = true;
          _syncTimer?.cancel();
          _turnTickTimer?.cancel();
          _onlineBotTimer?.cancel();
          _clearActiveRoom();
          if (mounted) {
            setState(() {
              _onlineRoomCode = null;
              _onlineGameStarted = false;
              _showStartLobby = true;
            });
            _showToast('تم استبعادك من الغرفة بواسطة المنشئ (Admin)');
          }
          return;
        }

        final isCreator = (data['isCreator'] == true) || (_onlinePlayerIndex == 0);
        _isRoomCreator = isCreator;

        final rawVotes = data['nextRoundVotes'];
        if (rawVotes is Map) {
          _nextRoundVotes = rawVotes.map((k, v) => MapEntry(int.tryParse(k.toString()) ?? 0, v == true));
          _isReadyForNextRound = _nextRoundVotes[_onlinePlayerIndex] == true;
        }

        final actions = data['actions'] as List? ?? [];
        final joined = data['joinedCount'] as int? ?? 1;
        final playersRaw = data['players'] as List? ?? [];
        final watchersRaw = data['watchers'] as List? ?? [];
        final roomTarget = (data['targetScore'] as int?) ?? _targetScore;
        final matchSeq = (data['matchSeq'] as int?) ?? _onlineMatchSeq;
        final started = (data['started'] as bool?) ?? false;
        final remMs = (data['turnRemainingMs'] as int?) ?? 60000;
        final myRole = (data['myRole'] as String?) ?? (_isWatcher ? 'watcher' : 'player');
        final myIdx = (data['myPlayerIndex'] as int?) ?? _onlinePlayerIndex;

        if (matchSeq != _onlineMatchSeq) {
          final playerNames = playersRaw.map((p) => (p['name'] as String?) ?? '').toList();
          if (mounted) {
            setState(() {
              _onlineMatchSeq = matchSeq;
              _onlineGameStarted = started;
              _onlineTurnRemainingMs = remMs;
              _turnSecondsLeft = (remMs / 1000).ceil();
              _onlineZeroSince = null;
              _onlinePlayersMeta = playersRaw.cast<Map<String, dynamic>>();
              _watchersMeta = watchersRaw.cast<Map<String, dynamic>>();
              _joinedPlayersCount = joined;
              _processedActionsCount = 0;
              _selectedTile = null;
              _setupDeal(
                (data['initialDeal'] ?? data['deal']) as Map<String, dynamic>,
                playerNames: playerNames,
                targetScore: roomTarget,
              );
              for (final act in actions) {
                _applyActionInternal(act as Map<String, dynamic>);
                _processedActionsCount++;
              }
            });
          }
          return;
        }

        if (mounted) {
          setState(() {
            _joinedPlayersCount = joined;
            _onlineGameStarted = started;
            _onlineTurnRemainingMs = remMs;
            _turnSecondsLeft = (remMs / 1000).ceil();
            if (remMs > 0) {
              _onlineZeroSince = null;
            } else {
              _onlineZeroSince ??= DateTime.now();
            }
            _onlinePlayersMeta = playersRaw.cast<Map<String, dynamic>>();
            _watchersMeta = watchersRaw.cast<Map<String, dynamic>>();

            // Handle live promotion from watcher to seated player (or eviction)
            if (myRole == 'player' && myIdx >= 0) {
              if (_isWatcher) {
                _isWatcher = false;
                _onlinePlayerIndex = myIdx;
                _saveActiveRoom(_onlineRoomCode!, myIdx);
                _showToast('تم إدخالك للعب مكان مقعد رقم ${myIdx + 1}!');
              } else {
                _onlinePlayerIndex = myIdx;
              }
            } else if (myRole == 'watcher' && !_isWatcher) {
              _isWatcher = true;
              _onlinePlayerIndex = -1;
            }

            if (_isWaitingForOpponents && (started || joined >= 4 || actions.isNotEmpty)) {
              _isWaitingForOpponents = false;
            }
            if (roomTarget != _controller.state.targetScore) {
              _targetScore = roomTarget;
              _controller.setTargetScore(roomTarget);
            }
          });
        }

        // Update player names dynamically if remote players joined or left/replaced
        if (playersRaw.isNotEmpty) {
          final names = playersRaw.map((p) => (p['name'] as String?) ?? '').toList();
          final isAiList = playersRaw.map((p) => p['isBot'] == true).toList();
          _controller.updatePlayerNames(names, isAiList: isAiList);

          if (_previousBots.isNotEmpty && _previousBots.length == isAiList.length) {
            for (int i = 0; i < isAiList.length; i++) {
              if (_previousBots[i] == true && !isAiList[i]) {
                final newName = names[i];
                _showToast('انضم $newName للعب مكان البوت في مقعد رقم ${i + 1}! 🎮');
              }
            }
          }
          _previousBots = isAiList;
        }

        while (_processedActionsCount < actions.length) {
          final action = actions[_processedActionsCount] as Map<String, dynamic>;
          _processedActionsCount++;

          final type = action['actionType'] as String?;
          final senderIndex = action['playerIndex'] as int?;
          final isAutoPlayed = action['autoPlayed'] == true;
          // Apply next_round, timeout autoPlayed moves, or remote players' moves
          if (type == 'next_round' || isAutoPlayed || senderIndex != _onlinePlayerIndex) {
            if (mounted) {
              setState(() {
                _applyActionInternal(action);
                _onlineZeroSince = null;
                _isAutoActing = false;
              });
            }
          }
        }
        _checkAndTriggerTurnVibration();
        _checkOnlineBotTurn();
      }
    } catch (_) {}
  }

  void _applyActionInternal(Map<String, dynamic> action) {
    final type = action['actionType'] as String;
    final pIdx = action['playerIndex'] as int;

    if (type == 'play') {
      final tileId = action['tileId'] as int?;
      final targetDirStr = action['targetDirection'] as String?;
      final sender = _controller.state.players[pIdx];
      int tileIndex = -1;
      if (tileId != null) {
        tileIndex = sender.hand.indexWhere((t) => t.id == tileId);
      }
      if (tileIndex == -1) {
        final head = action['head'] as int?;
        final tail = action['tail'] as int?;
        if (head != null && tail != null) {
          tileIndex = sender.hand.indexWhere((t) =>
              (t.head == head && t.tail == tail) ||
              (t.head == tail && t.tail == head));
        }
      }
      if (tileIndex == -1 && sender.hand.isNotEmpty) {
        tileIndex = 0;
      }
      if (tileIndex == -1) return;
      final tile = sender.hand[tileIndex];

      OpenEnd? targetEnd;
      if (_controller.state.board.openEnds.isNotEmpty) {
        final targetBranchStr = action['targetBranch'] as String? ?? targetDirStr;
        if (targetBranchStr != null) {
          targetEnd = _controller.state.board.openEnds.firstWhere(
            (e) => e.branch.name == targetBranchStr,
            orElse: () => _controller.state.board.openEnds.firstWhere(
              (e) => e.attachDirection.name == targetBranchStr,
              orElse: () => _controller.state.board.openEnds.first,
            ),
          );
        }
      }

      _controller.playTile(
        playerIndex: pIdx,
        tile: tile,
        targetEnd: targetEnd,
      );
    } else if (type == 'pass') {
      _controller.passTurn(pIdx);
    } else if (type == 'draw') {
      _controller.drawTile(pIdx);
    } else if (type == 'next_round') {
      final serverRound = action['roundNumber'] as int?;
      if (serverRound != null && serverRound <= _controller.state.roundNumber) {
        return;
      }
      final dealRaw = action['deal'] as Map<String, dynamic>;
      final starter = (action['playerIndex'] as int?) ?? (dealRaw['starter'] as int? ?? 0);
      final handsRaw = dealRaw['hands'] as List? ?? [];
      final hands = handsRaw.map((h) => _parseTiles(h as List)).toList();
      final boneyard = _parseTiles(dealRaw['boneyard'] as List? ?? []);

      _controller.startNextRoundWithDeal(
        hands: hands,
        boneyard: boneyard,
        startingPlayerIndex: starter,
      );
      _selectedTile = null;
      _nextRoundVotes.clear();
      _isReadyForNextRound = false;
    }

    _resetLocalTurnTimer();
    _checkSaveMatchRecord();
    _checkAndTriggerTurnVibration();
    _checkOnlineBotTurn();
  }

  Future<void> _requestNextOnlineRound() async {
    if (_onlineRoomCode == null || _isRequestingNextRound) return;
    _isRequestingNextRound = true;
    try {
      final winnerIdx = _controller.state.roundWinnerIndex ?? 0;
      final token = _playerToken ?? await _getOrCreatePlayerToken();
      await OnlineRoomManager.voteReadyForNextRound(
        code: _onlineRoomCode!,
        playerToken: token,
        playerIndex: _onlinePlayerIndex,
        winnerIndex: winnerIdx,
      );
      await _syncRoom();
    } catch (_) {
      _showToast('تعذر بدء الدور التالي: تحقق من الاتصال');
    } finally {
      _isRequestingNextRound = false;
    }
  }

  Future<void> _requestNewOnlineMatch() async {
    if (_onlineRoomCode == null) return;
    try {
      await OnlineRoomManager.newMatch(
        code: _onlineRoomCode!,
        targetScore: _targetScore,
      );
      await _syncRoom();
    } catch (_) {
      _showToast('تعذر بدء بولة جديدة: تحقق من الاتصال');
    }
  }

  Future<void> _vacateSeat(int slotIndex) async {
    if (_onlineRoomCode == null) return;
    try {
      await OnlineRoomManager.vacateSeat(code: _onlineRoomCode!, slotIndex: slotIndex);
      await _syncRoom();
      _showToast('تم إخلاء المقعد ${slotIndex + 1} بنجاح، يمكن للاعب أو مشاهد آخر الانضمام الآن');
    } catch (_) {
      _showToast('تعذر إخلاء المقعد');
    }
  }

  Future<void> _promoteWatcher({required int slotIndex, String? watcherId}) async {
    if (_onlineRoomCode == null) return;
    try {
      await OnlineRoomManager.promoteWatcher(
        code: _onlineRoomCode!,
        slotIndex: slotIndex,
        watcherId: watcherId,
      );
      await _syncRoom();
      _showToast('تم استبدال المقعد ${slotIndex + 1} بالمشاهد بنجاح');
    } catch (_) {
      _showToast('تعذر تبديل المقعد');
    }
  }

  Future<void> _startOnlineGameEarly() async {
    if (_onlineRoomCode == null) return;
    setState(() => _isWaitingForOpponents = false);
    try {
      await OnlineRoomManager.startOnlineGameEarly(code: _onlineRoomCode!);
      await _syncRoom();
      _checkOnlineBotTurn();
    } catch (_) {}
  }

  int? _botActiveTurnIndex;

  void _checkOnlineBotTurn() {
    if (_gameMode != GameMode.onlineMultiplayer || _onlineRoomCode == null) return;
    if (!_onlineGameStarted || _isWaitingForOpponents) return;
    final state = _controller.state;
    if (state.isRoundOver || state.isGameOver) {
      _onlineBotTimer?.cancel();
      _botActiveTurnIndex = null;
      return;
    }

    final activeIdx = state.activePlayerIndex;
    final isBot = (_onlinePlayersMeta.length > activeIdx && _onlinePlayersMeta[activeIdx]['isBot'] == true) ||
        state.players[activeIdx].isAi;

    if (!isBot) {
      _onlineBotTimer?.cancel();
      _botActiveTurnIndex = null;
      return;
    }

    if (_isWatcher || _onlinePlayerIndex < 0) return;

    // Guard: If a timer is already counting down for this bot's turn, do NOT cancel it!
    if (_onlineBotTimer != null && _onlineBotTimer!.isActive && _botActiveTurnIndex == activeIdx) {
      return;
    }

    _botActiveTurnIndex = activeIdx;
    _onlineBotTimer?.cancel();

    // Primary human driver triggers after 700ms; backup triggers after 1600ms
    final primaryDriverIdx = _findPrimaryHumanDriverIndex();
    final amPrimary = (_onlinePlayerIndex == primaryDriverIdx);
    final delayMs = amPrimary ? 700 : 1600;

    _onlineBotTimer = Timer(Duration(milliseconds: delayMs), () {
      _onlineBotTimer = null;
      _botActiveTurnIndex = null;
      if (!mounted || _isAutoActing) return;
      final cur = _controller.state;
      if (cur.isRoundOver || cur.isGameOver) return;
      if (cur.activePlayerIndex != activeIdx) return;

      _performOnlineBotMove(activeIdx);
    });
  }

  int _findPrimaryHumanDriverIndex() {
    for (int i = 0; i < _onlinePlayersMeta.length; i++) {
      final p = _onlinePlayersMeta[i];
      if (p['joined'] == true && p['isBot'] != true) {
        return i;
      }
    }
    return 0;
  }

  Future<void> _performOnlineBotMove(int botIdx) async {
    if (_isAutoActing || _onlineRoomCode == null || _controller.state.isRoundOver) return;
    _isAutoActing = true;
    final state = _controller.state;
    final hand = state.players[botIdx].hand;
    final board = state.board;

    final decision = HeuristicBot.decideMove(
      hand: hand,
      board: board,
      boneyardHasTiles: state.boneyard.isNotEmpty,
    );

    try {
      String actionType;
      int? tileId;
      String? targetDir;
      String? targetBranch;

      switch (decision.action) {
        case BotActionType.play:
          actionType = 'play';
          tileId = decision.tile?.id;
          targetDir = decision.targetEnd?.attachDirection.name;
          targetBranch = decision.targetEnd?.branch.name;
          break;
        case BotActionType.draw:
          actionType = 'draw';
          break;
        case BotActionType.pass:
          actionType = 'pass';
          break;
      }

      await OnlineRoomManager.sendAction(
        code: _onlineRoomCode!,
        action: {
          'roomCode': _onlineRoomCode,
          'playerIndex': botIdx,
          'actionType': actionType,
          'tileId': tileId,
          'head': decision.tile?.head,
          'tail': decision.tile?.tail,
          'targetDirection': targetDir,
          'targetBranch': targetBranch,
          'autoPlayed': true,
        },
      );
      await _syncRoom();
    } catch (_) {
    } finally {
      _isAutoActing = false;
    }
  }

  Future<void> _voteReadyForNextRound() async {
    if (_onlineRoomCode == null || _isReadyForNextRound) return;
    setState(() => _isReadyForNextRound = true);
    try {
      final token = _playerToken ?? await _getOrCreatePlayerToken();
      final winnerIdx = _controller.state.roundWinnerIndex ?? _controller.state.activePlayerIndex;
      await OnlineRoomManager.voteReadyForNextRound(
        code: _onlineRoomCode!,
        playerToken: token,
        playerIndex: _onlinePlayerIndex,
        winnerIndex: winnerIdx,
      );
      await _syncRoom();
    } catch (_) {
      setState(() => _isReadyForNextRound = false);
      _showToast('تعذر تأكيد الجاهزية: تحقق من الاتصال');
    }
  }

  void _confirmKickPlayer(int targetIndex, String targetName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2C1E14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5),
        ),
        title: Row(
          children: [
            const Icon(Icons.person_remove, color: Colors.redAccent, size: 26),
            const SizedBox(width: 8),
            Text(
              'طرد لاعب من الغرفة',
              style: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Text(
          'هل تريد بالتأكيد طرد "$targetName" من الغرفة؟\nسيتم استبداله ببوت فوراً لإكمال اللعبة.',
          style: GoogleFonts.cairo(color: Colors.white, fontSize: 13.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('إلغاء', style: GoogleFonts.cairo(color: Colors.white70)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red.shade800),
            onPressed: () {
              Navigator.pop(ctx);
              _kickPlayer(targetIndex);
            },
            child: Text('طرد اللاعب', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Future<void> _kickPlayer(int targetIndex) async {
    if (_onlineRoomCode == null) return;
    try {
      final token = _playerToken ?? await _getOrCreatePlayerToken();
      await OnlineRoomManager.kickPlayer(
        code: _onlineRoomCode!,
        adminToken: token,
        targetIndex: targetIndex,
      );
      _showToast('تم طرد اللاعب واستبداله ببوت 🤖');
      await _syncRoom();
    } catch (_) {
      _showToast('تعذر طرد اللاعب: تحقق من الاتصال');
    }
  }

  Future<void> _updateTargetScore(int newTarget) async {
    if (newTarget < 1) return;
    await _saveTargetScore(newTarget);
    setState(() {
      _targetScore = newTarget;
      _controller.setTargetScore(newTarget);
    });
    if (_gameMode == GameMode.onlineMultiplayer && _onlineRoomCode != null) {
      try {
        await OnlineRoomManager.updateTargetScore(
          code: _onlineRoomCode!,
          targetScore: newTarget,
        );
      } catch (_) {}
    }
    _showToast('تم ضبط هدف البولة على $newTarget نقطة');
  }

  Future<void> _broadcastAction({
    required String actionType,
    int? tileId,
    String? targetDirection,
    String? targetBranch,
  }) async {
    if (_gameMode != GameMode.onlineMultiplayer || _onlineRoomCode == null) return;
    try {
      await OnlineRoomManager.sendAction(
        code: _onlineRoomCode!,
        action: {
          'roomCode': _onlineRoomCode,
          'playerIndex': _onlinePlayerIndex,
          'actionType': actionType,
          'tileId': tileId,
          'targetDirection': targetDirection,
          'targetBranch': targetBranch,
        },
      );
      _processedActionsCount++;
    } catch (_) {}
  }

  void _checkSaveMatchRecord() {
    if (_controller.state.isGameOver && !_hasSavedThisMatch) {
      _hasSavedThisMatch = true;
      final winnerIdx = _controller.state.gameWinnerIndex ?? 0;
      final winnerName = _controller.state.players[winnerIdx].name;

      final results = _controller.state.players.map((p) {
        String? uid;
        if (p.id < _onlinePlayersMeta.length) {
          uid = _onlinePlayersMeta[p.id]['userId'] as String?;
        }
        return PlayerMatchResult(
          userId: uid,
          name: p.name,
          score: p.score,
          isWinner: p.id == winnerIdx,
        );
      }).toList();

      final record = MatchRecord(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        date: DateTime.now(),
        roomCode: _onlineRoomCode,
        targetScore: _controller.state.targetScore,
        roundsPlayed: _controller.state.roundNumber,
        winnerName: winnerName,
        players: results,
      );

      final isOnline = _gameMode == GameMode.onlineMultiplayer && _onlineRoomCode != null;
      MatchHistoryManager.saveMatch(
        record,
        syncToServer: isOnline,
        matchKey: isOnline ? 'online_${_onlineRoomCode}_m$_onlineMatchSeq' : null,
      );
    }
  }

  void _checkBotTurn() {
    if (_gameMode != GameMode.vsComputer) return;

    final state = _controller.state;
    if (state.isRoundOver || state.isGameOver) return;

    final activeIdx = state.activePlayerIndex;
    if (state.players[activeIdx].isAi && !_isBotThinking) {
      setState(() => _isBotThinking = true);

      Timer(const Duration(milliseconds: 900), () {
        if (!mounted) return;

        final decision = HeuristicBot.decideMove(
          hand: state.players[activeIdx].hand,
          board: state.board,
          boneyardHasTiles: state.boneyard.isNotEmpty,
        );

        setState(() {
          _isBotThinking = false;
          switch (decision.action) {
            case BotActionType.play:
              _controller.playTile(
                playerIndex: activeIdx,
                tile: decision.tile!,
                targetEnd: decision.targetEnd,
              );
              break;
            case BotActionType.draw:
              _controller.drawTile(activeIdx);
              break;
            case BotActionType.pass:
              _controller.passTurn(activeIdx);
              break;
          }
        });

        _checkSaveMatchRecord();
        _checkAndTriggerTurnVibration();

        if (!_controller.state.isRoundOver && _controller.state.activePlayer.isAi) {
          _checkBotTurn();
        }
      });
    }
  }

  void _onPlayerSelectTile(DominoTile tile) {
    final activeIdx = _controller.state.activePlayerIndex;

    if (_gameMode == GameMode.onlineMultiplayer && (_isWatcher || activeIdx != _onlinePlayerIndex)) {
      _showToast(_isWatcher
          ? 'أنت في وضع المشاهدة فقط'
          : 'انتظر دورك! الدور الحالي للاعب ${_controller.state.players[activeIdx].name}');
      return;
    }
    if (_gameMode == GameMode.vsComputer && (activeIdx != 0 || _isBotThinking)) return;

    final board = _controller.state.board;

    // Egyptian Rule: Opening tile MUST be a double (بفّة)!
    if (board.isEmpty) {
      if (!tile.isDouble) {
        _showToast('🚫 الفتحة لازم تكون بفة (ورقة بنفس القيمة من الطرفين)!');
        return;
      }

      setState(() {
        _controller.playTile(playerIndex: activeIdx, tile: tile);
        _selectedTile = null;
        _resetLocalTurnTimer();
      });
      VibrationHelper.lightFeedback();
      _broadcastAction(actionType: 'play', tileId: tile.id);
      _checkSaveMatchRecord();
      if (_gameMode == GameMode.vsComputer) _checkBotTurn();
      _checkAndTriggerTurnVibration();
      _checkOnlineBotTurn();
      return;
    }

    final legalEnds = board.findLegalPlacements(tile);
    if (legalEnds.isEmpty) {
      _showToast('الورقة دي ملهاش نزلة على الطاولة دلوقتي');
      return;
    }

    // If only 1 legal spot on board, play directly!
    if (legalEnds.length == 1) {
      final end = legalEnds.first;
      setState(() {
        _controller.playTile(
          playerIndex: activeIdx,
          tile: tile,
          targetEnd: end,
        );
        _selectedTile = null;
        _resetLocalTurnTimer();
      });
      VibrationHelper.lightFeedback();
      _broadcastAction(
        actionType: 'play',
        tileId: tile.id,
        targetDirection: end.attachDirection.name,
        targetBranch: end.branch.name,
      );
      _checkSaveMatchRecord();
      if (_gameMode == GameMode.vsComputer) _checkBotTurn();
      _checkAndTriggerTurnVibration();
      _checkOnlineBotTurn();
      return;
    }

    // Multiple legal ends: select tile and show directional quick pills above hand!
    setState(() {
      _selectedTile = (_selectedTile == tile) ? null : tile;
    });
  }

  void _onSelectTargetEnd(OpenEnd end) {
    final activeIdx = _controller.state.activePlayerIndex;
    if (_selectedTile == null) return;
    if (_gameMode == GameMode.onlineMultiplayer && (_isWatcher || activeIdx != _onlinePlayerIndex)) return;

    final playedTile = _selectedTile!;
    setState(() {
      _controller.playTile(
        playerIndex: activeIdx,
        tile: playedTile,
        targetEnd: end,
      );
      _selectedTile = null;
      _resetLocalTurnTimer();
    });
    VibrationHelper.lightFeedback();

    _broadcastAction(
      actionType: 'play',
      tileId: playedTile.id,
      targetDirection: end.attachDirection.name,
      targetBranch: end.branch.name,
    );
    _checkSaveMatchRecord();
    if (_gameMode == GameMode.vsComputer) _checkBotTurn();
    _checkAndTriggerTurnVibration();
    _checkOnlineBotTurn();
  }

  void _onPlayerPass() {
    final activeIdx = _controller.state.activePlayerIndex;
    if (_gameMode == GameMode.onlineMultiplayer && (_isWatcher || activeIdx != _onlinePlayerIndex)) return;

    setState(() {
      _controller.passTurn(activeIdx);
      _selectedTile = null;
      _resetLocalTurnTimer();
    });
    _broadcastAction(actionType: 'pass');
    _checkSaveMatchRecord();
    if (_gameMode == GameMode.vsComputer) _checkBotTurn();
    _checkAndTriggerTurnVibration();
    _checkOnlineBotTurn();
  }

  void _showToast(String message, {bool isError = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          message,
          textAlign: TextAlign.center,
          style: GoogleFonts.cairo(
            color: Colors.white,
            fontSize: 13.5,
            fontWeight: FontWeight.bold,
          ),
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        backgroundColor: isError ? const Color(0xFFB71C1C) : const Color(0xFF1F2D1B),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(
            color: isError ? const Color(0xFFFF8A80) : const Color(0xFFD4AF37),
            width: 1.2,
          ),
        ),
      ),
    );
  }

  String _directionArabicName(OpenEnd end) {
    switch (end.branch) {
      case Direction.east: return 'يمين ➡️';
      case Direction.west: return 'شمال ⬅️';
      case Direction.north: return 'فوق ⬆️';
      case Direction.south: return 'تحت ⬇️';
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.state;
    final activeIdx = state.activePlayerIndex;

    final thisDeviceIndex = (_gameMode == GameMode.onlineMultiplayer)
        ? (_isWatcher ? 0 : _onlinePlayerIndex)
        : activeIdx;
    final thisDevicePlayer = state.players[thisDeviceIndex];

    final isMyTurn = (_gameMode == GameMode.onlineMultiplayer)
        ? (!_isWatcher && activeIdx == _onlinePlayerIndex)
        : (_gameMode == GameMode.passAndPlay || (activeIdx == 0 && !_isBotThinking));

    final canActivePlay = !_isWatcher && _controller.hasLegalMove(thisDeviceIndex);

    // If a tile is selected, get its legal ends
    final selectedLegalEnds = _selectedTile != null
        ? state.board.findLegalPlacements(_selectedTile!)
        : <OpenEnd>[];

    final size = MediaQuery.of(context).size;
    final isLandscape = size.width > size.height;

    return Scaffold(
      backgroundColor: const Color(0xFF1B2817),
      body: Stack(
        children: [
          if (isLandscape)
            _buildLandscapeLayout(
              state: state,
              activeIdx: activeIdx,
              thisDeviceIndex: thisDeviceIndex,
              thisDevicePlayer: thisDevicePlayer,
              isMyTurn: isMyTurn,
              canActivePlay: canActivePlay,
              selectedLegalEnds: selectedLegalEnds,
              screenWidth: size.width,
            )
          else
            SafeArea(
              child: _buildPortraitLayout(
                state: state,
                activeIdx: activeIdx,
                thisDeviceIndex: thisDeviceIndex,
                thisDevicePlayer: thisDevicePlayer,
                isMyTurn: isMyTurn,
                canActivePlay: canActivePlay,
                selectedLegalEnds: selectedLegalEnds,
                screenWidth: size.width,
              ),
            ),

          // Waiting Room Overlay (Online 4-player mode)
          if (_gameMode == GameMode.onlineMultiplayer && _isWaitingForOpponents)
            _buildWaitingRoomOverlay(),

          // Round-Over / Game-Over Overlay
          if (state.isRoundOver && !_showStartLobby)
            _buildRoundOverOverlay(state),

          // Start Lobby Overlay (Room Create / Join before dealing cards)
          if (_showStartLobby)
            _buildStartLobbyOverlay(),
        ],
      ),
    );
  }

  Widget _buildLandscapeLayout({
    required GameState state,
    required int activeIdx,
    required int thisDeviceIndex,
    required Player thisDevicePlayer,
    required bool isMyTurn,
    required bool canActivePlay,
    required List<OpenEnd> selectedLegalEnds,
    required double screenWidth,
  }) {
    final safePadding = MediaQuery.of(context).padding;
    final sidebarWidth = (screenWidth * 0.16).clamp(130.0, 150.0);

    return Container(
      color: const Color(0xFF1B2817),
      child: Row(
        children: [
          // 1. Compact Sidebar
          SizedBox(
            width: sidebarWidth + safePadding.right,
            child: _buildLandscapeSidebar(
              state: state,
              activeIdx: activeIdx,
              thisDeviceIndex: thisDeviceIndex,
              safeRight: safePadding.right,
            ),
          ),

          // 2. Main Play Area (Huge Domino Table + Bottom Sleek Hand Rack)
          Expanded(
            child: Column(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      BoardCanvasWidget(
                        board: state.board,
                        selectedTile: _selectedTile,
                        onSelectTargetEnd: _onSelectTargetEnd,
                        onTableTapped: () {
                          if (_selectedTile != null) {
                            setState(() => _selectedTile = null);
                          }
                        },
                      ),

                      // Floating Quick Direction Pills in Landscape
                      if (_selectedTile != null && selectedLegalEnds.length > 1)
                        Positioned(
                          left: 16 + safePadding.left,
                          right: 16,
                          bottom: 8,
                          child: _buildQuickDirectionSelector(selectedLegalEnds, compact: true),
                        ),
                    ],
                  ),
                ),

                // Compact Bottom Hand Rack
                _buildLandscapePlayerRack(
                  player: thisDevicePlayer,
                  activePlayerName: state.players[activeIdx].name,
                  isMyTurn: isMyTurn,
                  canPlay: canActivePlay,
                  boardIsEmpty: state.board.isEmpty,
                  safeBottom: safePadding.bottom,
                  safeLeft: safePadding.left,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeSidebar({
    required GameState state,
    required int activeIdx,
    required int thisDeviceIndex,
    double safeRight = 0.0,
  }) {
    return Container(
      padding: EdgeInsets.only(right: safeRight),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1008),
        border: Border(left: BorderSide(color: Color(0xFF5A3E26), width: 1.5)),
      ),
      child: Column(
        children: [
          // Top compact room & actions bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            color: const Color(0xFF120A04),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _gameMode == GameMode.onlineMultiplayer ? _showRoomDialog : null,
                    child: Row(
                      children: [
                        Icon(
                          _onlineRoomCode != null ? Icons.wifi : Icons.casino,
                          size: 13,
                          color: const Color(0xFFD4AF37),
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            _onlineRoomCode != null ? '#$_onlineRoomCode' : 'دومينو',
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.cairo(
                              fontSize: 10.5,
                              fontWeight: FontWeight.bold,
                              color: const Color(0xFFD4AF37),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_onlineRoomCode != null)
                      InkWell(
                        onTap: _leaveRoom,
                        child: const Padding(
                          padding: EdgeInsets.all(3.0),
                          child: Icon(Icons.logout, size: 14, color: Colors.redAccent),
                        ),
                      ),
                    InkWell(
                      onTap: () => showDialog(
                        context: context,
                        builder: (_) => MatchHistoryDialog(currentUserId: _currentUser?.userId),
                      ),
                      child: const Padding(
                        padding: EdgeInsets.all(3.0),
                        child: Icon(Icons.history_edu, size: 14, color: Colors.amber),
                      ),
                    ),
                    if (_gameMode == GameMode.onlineMultiplayer && _onlineRoomCode == null)
                      InkWell(
                        onTap: _showRoomDialog,
                        child: const Padding(
                          padding: EdgeInsets.all(3.0),
                          child: Icon(Icons.meeting_room, size: 14, color: Color(0xFF81C784)),
                        ),
                      ),
                    _buildSettingsPopup(iconSize: 15),
                  ],
                ),
              ],
            ),
          ),

          // Round & Timer Pill (removed Target to maximize width and clarity)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: const Color(0xFFFBF8EE).withValues(alpha: 0.06),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'دور ${state.roundNumber}',
                  style: GoogleFonts.cairo(fontSize: 10, fontWeight: FontWeight.bold, color: const Color(0xFFD4AF37)),
                ),
                _buildTurnTimerChip(compact: true),
              ],
            ),
          ),
          if (_onlineRoomCode != null && _watchersMeta.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: const Color(0xFF140B05),
              child: Text(
                '👁️ ${_watchersMeta.length}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.cairo(fontSize: 9.5, color: Colors.amber.shade200),
              ),
            ),

          // 4 Unified Player Cards
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              child: Column(
                children: state.players.map((p) {
                  final color = ScoreboardNawtaWidget.playerColors[p.id % 4];
                  final isActive = p.id == activeIdx;
                  final isMe = !_isWatcher && p.id == thisDeviceIndex;

                  return Expanded(
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 1.5),
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      decoration: BoxDecoration(
                        color: isActive ? color.withValues(alpha: 0.22) : const Color(0xFF24160C),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isActive ? color : const Color(0xFF3E2918),
                          width: isActive ? 1.5 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      width: 6,
                                      height: 6,
                                      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                                    ),
                                    const SizedBox(width: 4),
                                    Flexible(
                                      child: Text(
                                        isMe ? '${p.name} (أنت)' : p.name,
                                        overflow: TextOverflow.ellipsis,
                                        style: GoogleFonts.cairo(
                                          fontSize: 10,
                                          fontWeight: isActive || isMe ? FontWeight.bold : FontWeight.w600,
                                          color: isActive ? Colors.amber : Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    Text(
                                      '🃏 ${p.hand.length}',
                                      style: GoogleFonts.cairo(fontSize: 9, color: Colors.white60),
                                    ),
                                    if (isActive) ...[
                                      const SizedBox(width: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0),
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF2E7D32),
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                        child: Text(
                                          'دوره',
                                          style: GoogleFonts.cairo(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '${p.score}',
                                style: GoogleFonts.cairo(
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFFD4AF37),
                                ),
                              ),
                              if (_gameMode == GameMode.onlineMultiplayer && _isRoomCreator && p.id != 0) ...[
                                const SizedBox(width: 2),
                                InkWell(
                                  onTap: () => _confirmKickPlayer(p.id, p.name),
                                  child: const Padding(
                                    padding: EdgeInsets.all(1.0),
                                    child: Icon(Icons.person_remove, size: 13, color: Colors.redAccent),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Compact Action Log at bottom of sidebar
          if (state.lastActionBanner.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              decoration: BoxDecoration(
                color: state.lastPointsScored > 0 ? const Color(0xFF2E7D32) : const Color(0xFF140B05),
                border: const Border(top: BorderSide(color: Color(0xFF5A3E26), width: 1)),
              ),
              child: Text(
                state.lastActionBanner,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: GoogleFonts.cairo(
                  fontSize: 9,
                  fontWeight: state.lastPointsScored > 0 ? FontWeight.bold : FontWeight.normal,
                  color: state.lastPointsScored > 0 ? Colors.amber.shade200 : Colors.white70,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildTurnTimerChip({bool compact = false}) {
    final isUrgent = _turnSecondsLeft <= 10;
    final isWarning = _turnSecondsLeft <= 20;
    final bg = isUrgent
        ? const Color(0xFFC62828)
        : (isWarning ? const Color(0xFFE65100) : const Color(0xFF2E7D32).withValues(alpha: 0.45));
    return Container(
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 8, vertical: compact ? 1 : 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isUrgent ? Colors.redAccent : (isWarning ? Colors.orangeAccent : const Color(0xFF81C784)),
          width: 1,
        ),
      ),
      child: Text(
        '⏱️ $_turnSecondsLeftث',
        style: GoogleFonts.cairo(
          fontSize: compact ? 9.5 : 11,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
    );
  }

  int get _firstOpenSeatIndex {
    return _onlinePlayersMeta.indexWhere((m) => (m['joined'] as bool?) == false);
  }

  Widget _buildWatcherBottomBar({
    required String activePlayerName,
    bool compact = false,
    double safeBottom = 0.0,
    double safeLeft = 0.0,
  }) {
    final openIdx = _firstOpenSeatIndex;
    final barHeight = (compact ? 58.0 : 74.0) + safeBottom;
    return Container(
      height: barHeight,
      width: double.infinity,
      padding: EdgeInsets.only(
        left: 14 + safeLeft,
        right: 14,
        top: 6,
        bottom: safeBottom > 0 ? safeBottom : 6,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF22140A),
        border: Border(top: BorderSide(color: Color(0xFF5A3E26), width: 1.5)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Row(
              children: [
                const Icon(Icons.visibility, color: Color(0xFFD4AF37), size: 18),
                const SizedBox(width: 8),
                Flexible(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '👁️ وضع المشاهدة فقط (أوراق اللاعبين مخفية)',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(fontSize: compact ? 10.5 : 12.5, fontWeight: FontWeight.bold, color: const Color(0xFFD4AF37)),
                      ),
                      Text(
                        'الدور الآن على: $activePlayerName • ⏱️ $_turnSecondsLeftث',
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(fontSize: compact ? 9.5 : 11, color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (openIdx != -1) ...[
            const SizedBox(width: 8),
            ElevatedButton.icon(
              onPressed: () => _promoteWatcher(slotIndex: openIdx),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              ),
              icon: const Icon(Icons.chair_alt, size: 14, color: Colors.white),
              label: Text(
                'العب مكان المقعد ${openIdx + 1}',
                style: GoogleFonts.cairo(fontSize: 10.5, fontWeight: FontWeight.bold, color: Colors.white),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildLandscapePlayerRack({
    required Player player,
    required String activePlayerName,
    required bool isMyTurn,
    required bool canPlay,
    required bool boardIsEmpty,
    double safeBottom = 0.0,
    double safeLeft = 0.0,
  }) {
    if (_isWatcher) {
      return _buildWatcherBottomBar(
        activePlayerName: activePlayerName,
        compact: true,
        safeBottom: safeBottom,
        safeLeft: safeLeft,
      );
    }
    final rackHeight = 62.0 + safeBottom;
    return Container(
      height: rackHeight,
      padding: EdgeInsets.only(
        left: 8 + safeLeft,
        right: 8,
        top: 3,
        bottom: safeBottom > 0 ? safeBottom : 3,
      ),
      decoration: const BoxDecoration(
        color: Color(0xFF22140A),
        border: Border(top: BorderSide(color: Color(0xFF5A3E26), width: 1.5)),
      ),
      child: Row(
        children: [
          // Turn badge & Pass Button
          SizedBox(
            width: 105,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: ScoreboardNawtaWidget.playerColors[player.id % 4],
                      ),
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isMyTurn ? 'دورك يا ${player.name}!' : 'دور $activePlayerName...',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.cairo(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: isMyTurn ? const Color(0xFF81C784) : Colors.white54,
                        ),
                      ),
                    ),
                  ],
                ),
                if (!canPlay && isMyTurn) ...[
                  const SizedBox(height: 3),
                  SizedBox(
                    height: 24,
                    child: ElevatedButton(
                      onPressed: _onPlayerPass,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFC62828),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        minimumSize: Size.zero,
                      ),
                      child: Text(
                        boardIsEmpty ? 'باص (معيش بفّة)' : 'باص!',
                        style: GoogleFonts.cairo(fontSize: 9.5, fontWeight: FontWeight.bold, color: Colors.white),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),

          const VerticalDivider(color: Color(0xFF5A3E26), width: 10),

          // Sleek Horizontal Tiles Row
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: player.hand.map((tile) {
                    final isPlayable = isMyTurn &&
                        (_controller.state.board.isEmpty
                            ? tile.isDouble
                            : _controller.state.board.findLegalPlacements(tile).isNotEmpty);
                    final isSelected = _selectedTile == tile;

                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2.0),
                      child: DominoTileWidget(
                        tile: tile,
                        width: 28.0,
                        height: 56.0,
                        isSelected: isSelected,
                        isPlayable: isPlayable,
                        onTap: isMyTurn ? () => _onPlayerSelectTile(tile) : null,
                      ),
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPortraitLayout({
    required GameState state,
    required int activeIdx,
    required int thisDeviceIndex,
    required Player thisDevicePlayer,
    required bool isMyTurn,
    required bool canActivePlay,
    required List<OpenEnd> selectedLegalEnds,
    required double screenWidth,
  }) {
    return Column(
      children: [
        _buildTopHeader(),

        if (screenWidth < 600)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 10),
            color: const Color(0xFF8B6F3E).withValues(alpha: 0.35),
            child: Text(
              '🔄 يفضل تدوير الموبايل بالعرض (Landscape) لتجربة لعب أوسع وأفضل',
              textAlign: TextAlign.center,
              style: GoogleFonts.cairo(fontSize: 10.5, color: Colors.amber.shade200),
            ),
          ),

        // 1. The 4-Player Authentic Scoreboard (النوتة)
        ScoreboardNawtaWidget(
          players: state.players,
          activePlayerIndex: activeIdx,
          targetScore: state.targetScore,
          roundNumber: state.roundNumber,
          onOpenHistory: () => showDialog(
            context: context,
            builder: (_) => MatchHistoryDialog(currentUserId: _currentUser?.userId),
          ),
        ),

        // 2. Opponents Bar (Showing other 3 players' tile count)
        _buildOtherPlayersBar(state.players, thisDeviceIndex, activeIdx),

        // 3. Central Domino Board (Expanded with seamless snapping & touch hit test)
        Expanded(
          child: BoardCanvasWidget(
            board: state.board,
            selectedTile: _selectedTile,
            onSelectTargetEnd: _onSelectTargetEnd,
            onTableTapped: () {
              if (_selectedTile != null) {
                setState(() => _selectedTile = null);
              }
            },
          ),
        ),

        // 4. Mobile Quick Direction Selector Bar (When multiple placements exist)
        if (_selectedTile != null && selectedLegalEnds.length > 1)
          _buildQuickDirectionSelector(selectedLegalEnds),

        // 5. Action Banner
        if (state.lastActionBanner.isNotEmpty)
          _buildActionBanner(state.lastActionBanner, state.lastPointsScored),

        // 6. Active Player Hand Rack
        _buildPlayerRack(
          player: thisDevicePlayer,
          isMyTurn: isMyTurn,
          canPlay: canActivePlay,
        ),
      ],
    );
  }

  Widget _buildTopHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
      color: const Color(0xFF140B05),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(_isWatcher ? Icons.visibility : Icons.casino, size: 18, color: const Color(0xFFD4AF37)),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    _onlineRoomCode != null
                        ? (_isWatcher
                            ? 'غرفة #$_onlineRoomCode (مشاهد)'
                            : 'غرفة #$_onlineRoomCode (${_controller.state.players[_onlinePlayerIndex].name})')
                        : 'دومينو أمريكاني (٤ لاعبين)',
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.cairo(
                      fontSize: 12.5,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFFD4AF37),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                _buildTurnTimerChip(compact: true),
              ],
            ),
          ),
          Row(
            children: [
              // Match History Button
              IconButton(
                icon: const Icon(Icons.history_edu, size: 20, color: Colors.amber),
                tooltip: 'سجل البولات القديمة',
                onPressed: () => showDialog(
                  context: context,
                  builder: (_) => MatchHistoryDialog(currentUserId: _currentUser?.userId),
                ),
              ),
              // Online Room Button
              if (_gameMode == GameMode.onlineMultiplayer) ...[
                ElevatedButton.icon(
                  onPressed: _showRoomDialog,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B6F3E),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                  icon: const Icon(Icons.wifi, size: 14, color: Colors.amber),
                  label: Text(
                    _onlineRoomCode != null ? 'غرفة #$_onlineRoomCode' : 'دخول غرفة',
                    style: GoogleFonts.cairo(fontSize: 11, color: Colors.white),
                  ),
                ),
                if (_onlineRoomCode != null) ...[
                  const SizedBox(width: 2),
                  IconButton(
                    icon: const Icon(Icons.logout, size: 18, color: Colors.redAccent),
                    tooltip: 'مغادرة الغرفة',
                    onPressed: _leaveRoom,
                  ),
                ],
                const SizedBox(width: 4),
              ],
              _buildSettingsPopup(iconSize: 20),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsPopup({double iconSize = 20}) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.settings, size: iconSize, color: Colors.amber),
      color: const Color(0xFF2C1E14),
      padding: EdgeInsets.zero,
      onSelected: (value) {
        if (value == 'target_score') {
          _showTargetScoreDialog();
          return;
        }
        final mode = GameMode.values.firstWhere((m) => m.name == value);
        setState(() {
          _gameMode = mode;
          _syncTimer?.cancel();
          _onlineRoomCode = null;
          _onlinePlayersMeta = [];
          _clearActiveRoom();
          _startMatch();
        });
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          value: 'target_score',
          child: Text('🎯 تحديد البولة (الحالي: $_targetScore نقطة)', style: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: GameMode.onlineMultiplayer.name,
          child: Text('🌐 ٤ لاعبين أونلاين (كل واحد من جهازه)', style: GoogleFonts.cairo(color: Colors.white)),
        ),
        PopupMenuItem(
          value: GameMode.passAndPlay.name,
          child: Text('👥 ٤ لاعبين على نفس الجهاز', style: GoogleFonts.cairo(color: Colors.white)),
        ),
        PopupMenuItem(
          value: GameMode.vsComputer.name,
          child: Text('🤖 ضد الكمبيوتر', style: GoogleFonts.cairo(color: Colors.white)),
        ),
      ],
    );
  }

  void _showTargetScoreDialog() {
    int selectedTarget = _targetScore;
    final customCtrl = TextEditingController(text: '$_targetScore');
    const presets = [21, 31, 41, 51, 101];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF2C1E14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5),
          ),
          title: Text(
            '🎯 تحديد هدف البولة',
            style: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'كل ٥ بنط = ١ نقطة (مثلاً ٢٠ بنط = ٤ نقط)',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(fontSize: 11.5, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: presets.map((val) {
                    final active = selectedTarget == val;
                    return ChoiceChip(
                      label: Text('$val', style: GoogleFonts.cairo(fontWeight: FontWeight.bold, color: active ? Colors.black : Colors.white)),
                      selected: active,
                      selectedColor: const Color(0xFFD4AF37),
                      backgroundColor: const Color(0xFF19110B),
                      onSelected: (_) {
                        setDialogState(() {
                          selectedTarget = val;
                          customCtrl.text = '$val';
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: customCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'أو أدخل رقم البولة يدوياً',
                    labelStyle: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF19110B),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) {
                    final parsed = int.tryParse(v.trim());
                    if (parsed != null && parsed >= 1) {
                      setDialogState(() => selectedTarget = parsed);
                    }
                  },
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('إلغاء', style: GoogleFonts.cairo(color: Colors.white70)),
            ),
            ElevatedButton(
              onPressed: () {
                final parsed = int.tryParse(customCtrl.text.trim()) ?? selectedTarget;
                Navigator.pop(ctx);
                _updateTargetScore(parsed < 1 ? 31 : parsed);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4AF37), foregroundColor: Colors.black),
              child: Text('حفظ', style: GoogleFonts.cairo(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildOtherPlayersBar(List<Player> players, int thisDeviceIdx, int activeIdx) {
    final otherPlayers = _isWatcher
        ? players
        : players.where((p) => p.id != thisDeviceIdx).toList();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 4.0),
      color: const Color(0xFF1E140C),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: otherPlayers.map((p) {
            final isActive = p.id == activeIdx;
            final color = ScoreboardNawtaWidget.playerColors[p.id % 4];

            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 3),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: isActive ? color.withValues(alpha: 0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: isActive ? color : Colors.white12),
              ),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 8,
                    backgroundColor: color,
                    child: Text(
                      '${p.id + 1}',
                      style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '${p.name}: ${p.hand.length} ورقات',
                    style: GoogleFonts.cairo(
                      fontSize: 11,
                      fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                      color: isActive ? Colors.amber : Colors.white70,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildQuickDirectionSelector(List<OpenEnd> ends, {bool compact = false}) {
    return Container(
      width: compact ? null : double.infinity,
      padding: EdgeInsets.symmetric(
        vertical: compact ? 6.0 : 8.0,
        horizontal: compact ? 12.0 : 10.0,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1E140C).withValues(alpha: compact ? 0.94 : 1.0),
        borderRadius: compact ? BorderRadius.circular(14) : null,
        border: compact
            ? Border.all(color: const Color(0xFFD4AF37), width: 1.5)
            : Border(
                top: BorderSide(color: const Color(0xFFD4AF37).withValues(alpha: 0.7), width: 1.5),
                bottom: BorderSide(color: const Color(0xFFD4AF37).withValues(alpha: 0.7), width: 1.5),
              ),
        boxShadow: compact
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.touch_app, size: 15, color: Colors.amber),
              const SizedBox(width: 5),
              Text(
                'اختر جهة النزول:',
                style: GoogleFonts.cairo(
                  fontSize: compact ? 11 : 12,
                  color: Colors.amber,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (_selectedTile != null) ...[
                const SizedBox(width: 6),
                Text(
                  '(${_selectedTile!.egyptianName})',
                  style: GoogleFonts.cairo(
                    fontSize: compact ? 11 : 12,
                    color: Colors.white70,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 5),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            alignment: WrapAlignment.center,
            children: ends.map((end) {
              return ElevatedButton(
                onPressed: () => _onSelectTargetEnd(end),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2E7D32),
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(
                    horizontal: compact ? 10 : 14,
                    vertical: compact ? 5 : 8,
                  ),
                  minimumSize: Size.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: const BorderSide(color: Color(0xFF81C784), width: 1.2),
                  ),
                  elevation: 3,
                ),
                child: Text(
                  '${_directionArabicName(end)} (${end.exposedPip})',
                  style: GoogleFonts.cairo(fontSize: compact ? 11.5 : 13, fontWeight: FontWeight.bold),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBanner(String text, int points) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 14.0),
      decoration: BoxDecoration(
        color: points > 0 ? const Color(0xFF2E7D32) : const Color(0xFF2C1E14),
        border: Border(
          top: BorderSide(color: points > 0 ? Colors.amber : const Color(0xFF5A3E26), width: 1),
          bottom: BorderSide(color: points > 0 ? Colors.amber : const Color(0xFF5A3E26), width: 1),
        ),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: GoogleFonts.cairo(
          fontSize: points > 0 ? 14 : 12,
          fontWeight: points > 0 ? FontWeight.bold : FontWeight.w500,
          color: points > 0 ? Colors.amber.shade200 : Colors.white,
        ),
      ),
    );
  }

  Widget _buildPlayerRack({
    required Player player,
    required bool isMyTurn,
    required bool canPlay,
  }) {
    if (_isWatcher) {
      final activeName = _controller.state.players[_controller.state.activePlayerIndex].name;
      return _buildWatcherBottomBar(activePlayerName: activeName, compact: false);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: const BoxDecoration(
        color: Color(0xFF22140A),
        border: Border(top: BorderSide(color: Color(0xFF5A3E26), width: 2)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: ScoreboardNawtaWidget.playerColors[player.id % 4],
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isMyTurn ? 'دورك الآن يا معلم (${player.name})!' : 'انتظر دور الخصم (${player.name})...',
                    style: GoogleFonts.cairo(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: isMyTurn ? const Color(0xFF81C784) : Colors.white54,
                    ),
                  ),
                ],
              ),
              if (!canPlay && isMyTurn)
                ElevatedButton(
                  onPressed: _onPlayerPass,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFC62828),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                    minimumSize: Size.zero,
                  ),
                  child: Text(
                    _controller.state.board.isEmpty ? 'باص (معيش بفّة)!' : 'باص!',
                    style: GoogleFonts.cairo(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: player.hand.map((tile) {
                final isPlayable = isMyTurn &&
                    (_controller.state.board.isEmpty
                        ? tile.isDouble
                        : _controller.state.board.findLegalPlacements(tile).isNotEmpty);
                final isSelected = _selectedTile == tile;

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 3.0),
                  child: DominoTileWidget(
                    tile: tile,
                    width: 42.0,
                    height: 84.0,
                    isSelected: isSelected,
                    isPlayable: isPlayable,
                    onTap: isMyTurn ? () => _onPlayerSelectTile(tile) : null,
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  String get _currentShareUrl {
    if (Uri.base.hasScheme && (Uri.base.scheme == 'http' || Uri.base.scheme == 'https')) {
      return Uri.base.origin;
    }
    return 'نفس رابط اللعبة';
  }

  Future<void> _showRoomDialog() async {
    final savedNick = await _getSavedNickname() ?? '';
    final nameCtrl = TextEditingController(text: savedNick);
    final codeCtrl = TextEditingController();
    final targetCtrl = TextEditingController(text: '$_targetScore');
    int selectedTarget = _targetScore;
    const targetPresets = [21, 31, 41, 51, 101];

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF2C1E14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFFD4AF37), width: 1.5),
          ),
          title: Row(
            children: [
              const Icon(Icons.wifi, color: Color(0xFFD4AF37), size: 22),
              const SizedBox(width: 8),
              Text(
                'غرفة أونلاين (٤ لاعبين)',
                style: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ],
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'العب مع صحابك: كل لاعب من موبايله على:\n$_currentShareUrl',
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(fontSize: 12, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                // Nickname field
                TextField(
                  controller: nameCtrl,
                  style: GoogleFonts.cairo(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    labelText: 'اسمك / لقبك في اللعبة',
                    labelStyle: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontSize: 12),
                    hintText: 'مثال: أحمد، المعلم، ...',
                    hintStyle: GoogleFonts.cairo(color: Colors.white38, fontSize: 12),
                    filled: true,
                    fillColor: const Color(0xFF19110B),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    prefixIcon: const Icon(Icons.person, color: Color(0xFFD4AF37), size: 18),
                  ),
                ),
                const SizedBox(height: 12),
                // Configurable البولة selector for creating room
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    '🎯 هدف البولة (بالنقط بعد القسمة على ٥):',
                    style: GoogleFonts.cairo(fontSize: 11.5, color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  alignment: WrapAlignment.center,
                  children: targetPresets.map((val) {
                    final active = selectedTarget == val;
                    return ChoiceChip(
                      label: Text('$val', style: GoogleFonts.cairo(fontSize: 11, fontWeight: FontWeight.bold, color: active ? Colors.black : Colors.white)),
                      selected: active,
                      selectedColor: const Color(0xFFD4AF37),
                      backgroundColor: const Color(0xFF19110B),
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) {
                        setDialogState(() {
                          selectedTarget = val;
                          targetCtrl.text = '$val';
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: targetCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.cairo(color: Colors.amber, fontSize: 14, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: 'أو رقم مخصص للبولة',
                    labelStyle: GoogleFonts.cairo(color: Colors.white70, fontSize: 11),
                    filled: true,
                    fillColor: const Color(0xFF19110B),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (v) {
                    final parsed = int.tryParse(v.trim());
                    if (parsed != null && parsed >= 1) {
                      setDialogState(() => selectedTarget = parsed);
                    }
                  },
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Colors.white38),
                          minimumSize: const Size.fromHeight(42),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text('تراجع (Decline)', style: GoogleFonts.cairo(color: Colors.white70, fontSize: 12)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 2,
                      child: ElevatedButton.icon(
                        onPressed: () {
                          final nick = nameCtrl.text.trim().isNotEmpty ? nameCtrl.text.trim() : 'لاعب ١';
                          final parsedTarget = int.tryParse(targetCtrl.text.trim()) ?? selectedTarget;
                          Navigator.pop(ctx);
                          _createOnlineRoom(nick, targetScore: parsedTarget < 1 ? 31 : parsedTarget);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF2E7D32),
                          minimumSize: const Size.fromHeight(42),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        icon: const Icon(Icons.add, color: Colors.white, size: 18),
                        label: Text('إنشاء غرفة جديدة', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Divider(color: Color(0xFF5A3E26)),
                const SizedBox(height: 8),
                TextField(
                  controller: codeCtrl,
                  keyboardType: TextInputType.number,
                  style: GoogleFonts.cairo(color: Colors.amber, fontSize: 18, fontWeight: FontWeight.bold),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'أدخل رقم الغرفة (٤ أرقام)',
                    hintStyle: GoogleFonts.cairo(color: Colors.white38, fontSize: 13),
                    filled: true,
                    fillColor: const Color(0xFF19110B),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                    prefixIcon: const Icon(Icons.meeting_room, color: Color(0xFFD4AF37), size: 18),
                  ),
                ),
                const SizedBox(height: 10),
                ElevatedButton.icon(
                  onPressed: () {
                    if (codeCtrl.text.trim().isNotEmpty) {
                      final nick = nameCtrl.text.trim();
                      Navigator.pop(ctx);
                      _joinOnlineRoom(codeCtrl.text.trim(), nickname: nick);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B6F3E),
                    minimumSize: const Size.fromHeight(42),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  icon: const Icon(Icons.login, color: Colors.white, size: 18),
                  label: Text('انضمام إلى الغرفة (أو مشاهدة)', style: GoogleFonts.cairo(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 6),
                OutlinedButton.icon(
                  onPressed: () {
                    if (codeCtrl.text.trim().isNotEmpty) {
                      final nick = nameCtrl.text.trim();
                      Navigator.pop(ctx);
                      _joinOnlineRoom(codeCtrl.text.trim(), nickname: nick, preferWatcher: true);
                    }
                  },
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFD4AF37)),
                    minimumSize: const Size.fromHeight(38),
                  ),
                  icon: const Icon(Icons.visibility, color: Color(0xFFD4AF37), size: 17),
                  label: Text('دخول كمشاهد فقط (بدون كروت)', style: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold, fontSize: 12.5)),
                ),
                if (_onlineRoomCode != null) ...[
                  const SizedBox(height: 14),
                  const Divider(color: Color(0xFF5A3E26)),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      'إدارة مقاعد الغرفة #$_onlineRoomCode (${_watchersMeta.length} مشاهد):',
                      style: GoogleFonts.cairo(fontSize: 11.5, color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(height: 6),
                  ...List.generate(_controller.state.players.length, (idx) {
                    final p = _controller.state.players[idx];
                    final meta = idx < _onlinePlayersMeta.length ? _onlinePlayersMeta[idx] : null;
                    final joined = meta != null ? (meta['joined'] as bool? ?? true) : true;
                    final online = meta != null ? (meta['online'] as bool? ?? joined) : joined;
                    final idleSec = meta?['idleSeconds'] as int?;
                    final statusLabel = !joined
                        ? '(متاح)'
                        : (online ? '🟢 متصل' : '🔴 غائب ${idleSec ?? 0}ث');

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Flexible(
                            child: Text(
                              '${idx + 1}. ${p.name} $statusLabel',
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.cairo(
                                fontSize: 11,
                                color: !joined
                                    ? Colors.greenAccent
                                    : (online ? Colors.white : Colors.orangeAccent),
                              ),
                            ),
                          ),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (!_isWatcher && idx != _onlinePlayerIndex && joined)
                                TextButton(
                                  onPressed: () {
                                    Navigator.pop(ctx);
                                    _vacateSeat(idx);
                                  },
                                  style: TextButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                    minimumSize: Size.zero,
                                  ),
                                  child: Text('إخلاء', style: GoogleFonts.cairo(fontSize: 10.5, color: Colors.orangeAccent)),
                                ),
                              if (_watchersMeta.isNotEmpty && (!joined || !online) && idx != _onlinePlayerIndex)
                                PopupMenuButton<String>(
                                  tooltip: 'استبدال بمشاهد',
                                  color: const Color(0xFF19110B),
                                  onSelected: (watcherId) {
                                    Navigator.pop(ctx);
                                    _promoteWatcher(slotIndex: idx, watcherId: watcherId);
                                  },
                                  itemBuilder: (_) => _watchersMeta
                                      .map((w) => PopupMenuItem<String>(
                                            value: w['id'] as String,
                                            child: Text('استبدال بـ ${w['name']}', style: GoogleFonts.cairo(color: Colors.white, fontSize: 12)),
                                          ))
                                      .toList(),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF2E7D32),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Text('استبدال بمشاهد', style: GoogleFonts.cairo(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold)),
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    );
                  }),
                  if (_watchersMeta.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '👁️ المشاهدون الآن: ${_watchersMeta.map((w) => w['name']).join('، ')}',
                        style: GoogleFonts.cairo(fontSize: 11, color: Colors.amber.shade200),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _leaveRoom();
                    },
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent),
                      minimumSize: const Size.fromHeight(38),
                    ),
                    icon: const Icon(Icons.exit_to_app, color: Colors.redAccent, size: 18),
                    label: Text(
                      _isWatcher ? 'مغادرة المشاهدة' : 'مغادرة الغرفة وإتاحة مقعدي',
                      style: GoogleFonts.cairo(color: Colors.redAccent, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildWaitingRoomOverlay() {
    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              padding: const EdgeInsets.all(18.0),
              decoration: BoxDecoration(
                color: const Color(0xFF2C1E14),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: const Color(0xFFD4AF37), width: 2),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(color: Color(0xFFD4AF37), strokeWidth: 3),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'في انتظار انضمام باقي اللاعبين ($_joinedPlayersCount من ٤)',
                    style: GoogleFonts.cairo(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    alignment: WrapAlignment.center,
                    children: _controller.state.players.take(_joinedPlayersCount).map((p) {
                      final color = ScoreboardNawtaWidget.playerColors[p.id % 4];
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF19110B),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: color, width: 1.2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircleAvatar(radius: 5, backgroundColor: color),
                            const SizedBox(width: 6),
                            Text(
                              p.name,
                              style: GoogleFonts.cairo(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                            if (_isRoomCreator && p.id != 0) ...[
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: () => _confirmKickPlayer(p.id, p.name),
                                child: const Icon(Icons.close, size: 14, color: Colors.redAccent),
                              ),
                            ],
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'رقم الغرفة: ${_onlineRoomCode ?? '...'}',
                    style: GoogleFonts.cairo(fontSize: 22, fontWeight: FontWeight.bold, color: const Color(0xFFD4AF37)),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'افتح المتصفح على هواتفكم على: $_currentShareUrl',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(fontSize: 11, color: Colors.white60),
                  ),
                  const SizedBox(height: 14),
                  if (_joinedPlayersCount >= 2) ...[
                    ElevatedButton.icon(
                      onPressed: _startOnlineGameEarly,
                      icon: const Icon(Icons.smart_toy, size: 18),
                      label: Text(
                        'بدء اللعب الآن (إكمال باقي المقاعد ببوتات 🤖)',
                        style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4AF37),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'أي صديق ينضم لاحقاً بكود الغرفة سيأخذ مكان البوت فوراً ويكمل اللعب معكم',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(fontSize: 11, color: Colors.greenAccent.shade100),
                    ),
                  ] else ...[
                    Text(
                      'في انتظار انضمام لاعب إضافي على الأقل لبدء اللعب مع البوتات (أو انتظر حتى يكتمل ٤ لاعبين)',
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(fontSize: 11, color: Colors.white54),
                    ),
                  ],
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _leaveRoom,
                    icon: const Icon(Icons.close, size: 16, color: Colors.redAccent),
                    label: Text(
                      'إلغاء الغرفة والتراجع (Decline)',
                      style: GoogleFonts.cairo(
                        fontSize: 12.5,
                        fontWeight: FontWeight.bold,
                        color: Colors.redAccent,
                      ),
                    ),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.redAccent, width: 1.2),
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _submitLobbyAuth() async {
    if (_isAuthSubmitting) return;
    final username = _authUserCtrl.text.trim();
    final pin = _authPinCtrl.text.trim();
    final display = _authDisplayCtrl.text.trim();

    if (username.length < 2) {
      _showToast('اسم المستخدم لازم يكون حرفين على الأقل', isError: true);
      return;
    }
    if (pin.length < 4) {
      _showToast('الرقم السري (PIN) لازم يكون ٤ أرقام على الأقل', isError: true);
      return;
    }

    setState(() => _isAuthSubmitting = true);
    final result = _isRegisterMode
        ? await AuthManager.register(username: username, pin: pin, displayName: display)
        : await AuthManager.login(username: username, pin: pin);

    if (!mounted) return;
    setState(() => _isAuthSubmitting = false);

    if (result.ok && result.user != null) {
      setState(() {
        _currentUser = result.user;
        _lobbyNameCtrl.text = result.user!.displayName;
        _authPinCtrl.clear();
      });
      _showToast('أهلاً بك يا ${result.user!.displayName}!');
    } else {
      _showToast(result.message ?? 'تعذر تسجيل الدخول', isError: true);
    }
  }

  Widget _buildAuthSection() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: ChoiceChip(
                label: Center(
                  child: Text(
                    'تسجيل الدخول',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: !_isRegisterMode ? Colors.black : Colors.white,
                    ),
                  ),
                ),
                selected: !_isRegisterMode,
                selectedColor: const Color(0xFFD4AF37),
                backgroundColor: const Color(0xFF19110B),
                onSelected: (_) => setState(() => _isRegisterMode = false),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ChoiceChip(
                label: Center(
                  child: Text(
                    'حساب جديد',
                    style: GoogleFonts.cairo(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isRegisterMode ? Colors.black : Colors.white,
                    ),
                  ),
                ),
                selected: _isRegisterMode,
                selectedColor: const Color(0xFFD4AF37),
                backgroundColor: const Color(0xFF19110B),
                onSelected: (_) => setState(() => _isRegisterMode = true),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _authUserCtrl,
          style: GoogleFonts.cairo(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            labelText: 'اسم المستخدم (مثال: ahmed)',
            labelStyle: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontSize: 12),
            filled: true,
            fillColor: const Color(0xFF19110B),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            prefixIcon: const Icon(Icons.alternate_email, color: Color(0xFFD4AF37), size: 18),
          ),
        ),
        if (_isRegisterMode) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _authDisplayCtrl,
            style: GoogleFonts.cairo(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              labelText: 'الاسم الظاهر في اللعب (اختياري)',
              labelStyle: GoogleFonts.cairo(color: Colors.white70, fontSize: 12),
              filled: true,
              fillColor: const Color(0xFF19110B),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              prefixIcon: const Icon(Icons.badge, color: Color(0xFFD4AF37), size: 18),
            ),
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _authPinCtrl,
          obscureText: true,
          keyboardType: TextInputType.number,
          style: GoogleFonts.cairo(color: Colors.amber, fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 4),
          textAlign: TextAlign.center,
          decoration: InputDecoration(
            labelText: 'الرقم السري (PIN من ٤ أرقام أو أكثر)',
            labelStyle: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontSize: 12, letterSpacing: 0),
            filled: true,
            fillColor: const Color(0xFF19110B),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            prefixIcon: const Icon(Icons.lock, color: Color(0xFFD4AF37), size: 18),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isAuthSubmitting ? null : _submitLobbyAuth,
            icon: _isAuthSubmitting
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : Icon(_isRegisterMode ? Icons.person_add : Icons.login),
            label: Text(
              _isRegisterMode ? 'تسجيل حساب جديد وحفظ سجلي' : 'دخول لحفظ سجلي',
              style: GoogleFonts.cairo(fontWeight: FontWeight.bold, fontSize: 13.5),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD4AF37),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 11),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStartLobbyOverlay() {
    const targetPresets = [21, 31, 41, 51, 101];
    final user = _currentUser;
    return Container(
      color: const Color(0xFF140B05).withValues(alpha: 0.94),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: const Color(0xFF2C1E14),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: const Color(0xFFD4AF37), width: 1.8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 18,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.casino, color: Color(0xFFD4AF37), size: 26),
                      const SizedBox(width: 8),
                      Text(
                        'دومينو أمريكاني',
                        style: GoogleFonts.cairo(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFD4AF37),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user == null
                        ? 'سجّل دخولك لحفظ نتائج البولات وترتيب الأصدقاء'
                        : 'أنشئ غرفة جديدة أو ادخل بكود الغرفة للعب مع أصدقائك',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(fontSize: 12, color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  if (user == null)
                    _buildAuthSection()
                  else ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF19110B),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFD4AF37).withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.verified_user, color: Colors.greenAccent, size: 18),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${user.displayName} (@${user.userId})',
                              style: GoogleFonts.cairo(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.bold),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          TextButton.icon(
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (_) => MatchHistoryDialog(currentUserId: user.userId),
                              );
                            },
                            icon: const Icon(Icons.emoji_events, size: 15, color: Color(0xFFD4AF37)),
                            label: Text('السجل', style: GoogleFonts.cairo(fontSize: 11.5, color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold)),
                          ),
                          IconButton(
                            icon: const Icon(Icons.logout, size: 17, color: Colors.redAccent),
                            tooltip: 'تسجيل الخروج',
                            onPressed: () async {
                              await AuthManager.logout();
                              if (!mounted) return;
                              setState(() => _currentUser = null);
                              _showToast('تم تسجيل الخروج');
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _lobbyNameCtrl,
                      style: GoogleFonts.cairo(color: Colors.white, fontSize: 14, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                      decoration: InputDecoration(
                        labelText: 'الاسم داخل الغرفة',
                        labelStyle: GoogleFonts.cairo(color: const Color(0xFFD4AF37), fontSize: 12),
                        filled: true,
                        fillColor: const Color(0xFF19110B),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                        prefixIcon: const Icon(Icons.person, color: Color(0xFFD4AF37), size: 18),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '🎯 هدف البولة (بالنقط بعد القسمة على ٥):',
                        style: GoogleFonts.cairo(
                          fontSize: 11.5,
                          color: const Color(0xFFD4AF37),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      alignment: WrapAlignment.center,
                      children: targetPresets.map((val) {
                        final active = _lobbyTargetScore == val;
                        return ChoiceChip(
                          label: Text(
                            '$val',
                            style: GoogleFonts.cairo(
                              fontSize: 11.5,
                              fontWeight: FontWeight.bold,
                              color: active ? Colors.black : Colors.white,
                            ),
                          ),
                          selected: active,
                          selectedColor: const Color(0xFFD4AF37),
                          backgroundColor: const Color(0xFF19110B),
                          visualDensity: VisualDensity.compact,
                          onSelected: (_) {
                            setState(() {
                              _lobbyTargetScore = val;
                              _lobbyTargetCtrl.text = '$val';
                            });
                          },
                        );
                      }).toList(),
                    ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 170,
                    child: TextField(
                      controller: _lobbyTargetCtrl,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: GoogleFonts.cairo(color: Colors.amber, fontSize: 13.5, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        labelText: 'أو رقم مخصص',
                        labelStyle: GoogleFonts.cairo(color: Colors.white70, fontSize: 11),
                        filled: true,
                        fillColor: const Color(0xFF19110B),
                        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      ),
                      onChanged: (v) {
                        final parsed = int.tryParse(v.trim());
                        if (parsed != null && parsed >= 1) {
                          setState(() => _lobbyTargetScore = parsed);
                        }
                      },
                    ),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () {
                        final custom = int.tryParse(_lobbyTargetCtrl.text.trim());
                        final chosenTarget = (custom != null && custom >= 1) ? custom : _lobbyTargetScore;
                        setState(() {
                          _gameMode = GameMode.onlineMultiplayer;
                          _targetScore = chosenTarget;
                        });
                        _createOnlineRoom(_lobbyNameCtrl.text.trim(), targetScore: chosenTarget);
                      },
                      icon: const Icon(Icons.add_circle_outline),
                      label: Text(
                        'إنشاء غرفة جديدة (هدف $_lobbyTargetScore)',
                        style: GoogleFonts.cairo(fontWeight: FontWeight.bold, fontSize: 13.5),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4AF37),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const Divider(color: Colors.white24, height: 24),
                  TextField(
                    controller: _lobbyCodeCtrl,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: GoogleFonts.cairo(color: Colors.amber, fontSize: 18, fontWeight: FontWeight.bold, letterSpacing: 4),
                    decoration: InputDecoration(
                      hintText: 'كود الغرفة (٤ أرقام)',
                      hintStyle: GoogleFonts.cairo(color: Colors.white38, fontSize: 12.5, letterSpacing: 0),
                      filled: true,
                      fillColor: const Color(0xFF19110B),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () {
                            final code = _lobbyCodeCtrl.text.trim();
                            if (code.length < 4) {
                              _showToast('من فضلك أدخل كود الغرفة المكون من ٤ أرقام', isError: true);
                              return;
                            }
                            setState(() => _gameMode = GameMode.onlineMultiplayer);
                            _joinOnlineRoom(code, nickname: _lobbyNameCtrl.text.trim());
                          },
                          icon: const Icon(Icons.login, size: 17),
                          label: Text('دخول كلاعب', style: GoogleFonts.cairo(fontWeight: FontWeight.bold, fontSize: 12.5)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2E7D32),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () {
                            final code = _lobbyCodeCtrl.text.trim();
                            if (code.length < 4) {
                              _showToast('من فضلك أدخل كود الغرفة المكون من ٤ أرقام', isError: true);
                              return;
                            }
                            setState(() => _gameMode = GameMode.onlineMultiplayer);
                            _joinOnlineRoom(code, nickname: _lobbyNameCtrl.text.trim(), preferWatcher: true);
                          },
                          icon: const Icon(Icons.visibility, size: 17, color: Color(0xFFD4AF37)),
                          label: Text('دخول كمشاهد', style: GoogleFonts.cairo(fontWeight: FontWeight.bold, fontSize: 12.5, color: const Color(0xFFD4AF37))),
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Color(0xFFD4AF37)),
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ),
                    ],
                  ),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _gameMode = GameMode.vsComputer;
                            _showStartLobby = false;
                            _startMatch();
                          });
                        },
                        icon: const Icon(Icons.smart_toy, size: 16, color: Colors.white70),
                        label: Text('لعب مع البوت', style: GoogleFonts.cairo(fontSize: 11.5, color: Colors.white70)),
                      ),
                      const SizedBox(width: 8),
                      TextButton.icon(
                        onPressed: () {
                          setState(() {
                            _gameMode = GameMode.passAndPlay;
                            _showStartLobby = false;
                            _startMatch();
                          });
                        },
                        icon: const Icon(Icons.people, size: 16, color: Colors.white70),
                        label: Text('لعب محلي', style: GoogleFonts.cairo(fontSize: 11.5, color: Colors.white70)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRoundOverOverlay(GameState state) {
    final isGameOver = state.isGameOver;
    final winnerIdx = state.roundWinnerIndex ?? state.activePlayerIndex;
    final isOnline = _gameMode == GameMode.onlineMultiplayer && _onlineRoomCode != null;

    int approvedCount = 0;
    int totalHumanPlayers = 0;
    for (int i = 0; i < state.players.length; i++) {
      final p = state.players[i];
      final isBot = p.isAi || (i < _onlinePlayersMeta.length && _onlinePlayersMeta[i]['isBot'] == true);
      if (!isBot) {
        totalHumanPlayers++;
        if (_nextRoundVotes[i] == true) approvedCount++;
      }
    }

    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Container(
              padding: const EdgeInsets.all(20.0),
              decoration: BoxDecoration(
                color: const Color(0xFF24160C),
                borderRadius: BorderRadius.circular(18.0),
                border: Border.all(color: const Color(0xFFD4AF37), width: 2),
                boxShadow: const [
                  BoxShadow(color: Colors.black87, blurRadius: 20, spreadRadius: 4),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Title Header
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        isGameOver ? Icons.emoji_events : Icons.military_tech,
                        size: 34,
                        color: const Color(0xFFD4AF37),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        isGameOver ? '🏆 انتهت البولة الرسمية!' : 'نهاية الدور ${state.roundNumber}',
                        style: GoogleFonts.cairo(
                          fontSize: 21,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFFD4AF37),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (state.lastActionBanner.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFF140B05),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFF5A3E26), width: 1),
                      ),
                      child: Text(
                        state.lastActionBanner,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.cairo(fontSize: 13, color: Colors.amber.shade200),
                      ),
                    ),
                  const SizedBox(height: 14),

                  // Section Title
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '📊 ملخص نقاط وخصومات اللاعبين بالدور:',
                      style: GoogleFonts.cairo(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.white70,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Vertical Cards for Every Player
                  Column(
                    children: state.players.map((p) {
                      final isWinner = p.id == winnerIdx;
                      final isMe = isOnline && p.id == _onlinePlayerIndex;
                      final isBot = p.isAi || (p.id < _onlinePlayersMeta.length && _onlinePlayersMeta[p.id]['isBot'] == true);
                      final color = ScoreboardNawtaWidget.playerColors[p.id % 4];

                      final pipSum = p.hand.fold<int>(0, (sum, t) => sum + t.pipSum);
                      final deduction = isWinner ? 0 : ScoringCalculator.calculateTakhleesScore(p.hand);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: isWinner
                              ? const Color(0xFF1B3A1E)
                              : const Color(0xFF19110B),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isWinner
                                ? const Color(0xFF81C784)
                                : isMe
                                    ? const Color(0xFFD4AF37)
                                    : const Color(0xFF3E2918),
                            width: isWinner || isMe ? 1.5 : 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          p.name,
                                          overflow: TextOverflow.ellipsis,
                                          style: GoogleFonts.cairo(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                      if (isMe) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: const Color(0xFFD4AF37).withValues(alpha: 0.25),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'أنت',
                                            style: GoogleFonts.cairo(fontSize: 9.5, color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ],
                                      if (isBot) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                                          decoration: BoxDecoration(
                                            color: Colors.blueGrey.withValues(alpha: 0.35),
                                            borderRadius: BorderRadius.circular(4),
                                          ),
                                          child: Text(
                                            'بوت 🤖',
                                            style: GoogleFonts.cairo(fontSize: 9.5, color: Colors.blueGrey.shade200, fontWeight: FontWeight.bold),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    isWinner
                                        ? '🏆 فائز بالدور '
                                        : 'باقي في يده: $pipSum بنط (${p.hand.length} ورقات) ➔ خصم: -$deduction نقطة',
                                    style: GoogleFonts.cairo(
                                      fontSize: 11.5,
                                      color: isWinner ? const Color(0xFF81C784) : Colors.redAccent.shade100,
                                      fontWeight: isWinner ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  '${p.score}',
                                  style: GoogleFonts.cairo(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: const Color(0xFFD4AF37),
                                  ),
                                ),
                                Text(
                                  'من أصل ${state.targetScore}',
                                  style: GoogleFonts.cairo(fontSize: 9.5, color: Colors.white54),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 12),

                  // Next Round Approval Status (when online and not game over)
                  if (isOnline && !isGameOver) ...[
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF140B05),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFF5A3E26), width: 1),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.how_to_reg, size: 16, color: Color(0xFFD4AF37)),
                              const SizedBox(width: 6),
                              Text(
                                'موافقة اللاعبين لبدء الدور التالي (مطلوب موافقة الكل):',
                                style: GoogleFonts.cairo(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: state.players.map((p) {
                              final isBot = p.isAi || (p.id < _onlinePlayersMeta.length && _onlinePlayersMeta[p.id]['isBot'] == true);
                              final hasVoted = _nextRoundVotes[p.id] == true;
                              final isReady = isBot || hasVoted;

                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: isReady ? const Color(0xFF1B3A1E) : const Color(0xFF2C1E14),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                    color: isReady ? Colors.green : Colors.white24,
                                    width: 1,
                                  ),
                                ),
                                child: Text(
                                  isBot
                                      ? '🤖 ${p.name}: موافق تلقائياً ✅'
                                      : hasVoted
                                          ? '✅ ${p.name}: جاهز'
                                          : '⏳ ${p.name}: في الانتظار...',
                                  style: GoogleFonts.cairo(
                                    fontSize: 10.5,
                                    fontWeight: isReady ? FontWeight.bold : FontWeight.normal,
                                    color: isReady ? const Color(0xFF81C784) : Colors.white70,
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                  ],

                  // Action Buttons
                  if (isGameOver)
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.center,
                      children: [
                        if (isOnline)
                          OutlinedButton.icon(
                            onPressed: _leaveRoom,
                            icon: const Icon(Icons.exit_to_app, size: 18, color: Colors.redAccent),
                            label: Text(
                              'رفض ومغادرة (Decline)',
                              style: GoogleFonts.cairo(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.redAccent),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.redAccent, width: 1.2),
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ElevatedButton.icon(
                          onPressed: () {
                            if (isOnline) {
                              _requestNewOnlineMatch();
                            } else {
                              _startMatch();
                            }
                          },
                          icon: const Icon(Icons.refresh, size: 20),
                          label: Text(
                            'ابدأ بولة جديدة',
                            style: GoogleFonts.cairo(fontSize: 14.5, fontWeight: FontWeight.bold),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFD4AF37),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                        ),
                      ],
                    )
                  else if (isOnline) ...[
                    if (_isWatcher)
                      Text(
                        '👁️ وضع المشاهدة: بانتظار موافقة اللاعبين لبدء الدور التالي...',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.cairo(fontSize: 12.5, color: Colors.amber.shade200, fontWeight: FontWeight.bold),
                      )
                    else if (!_isReadyForNextRound)
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        alignment: WrapAlignment.center,
                        children: [
                          OutlinedButton.icon(
                            onPressed: _leaveRoom,
                            icon: const Icon(Icons.exit_to_app, size: 17, color: Colors.redAccent),
                            label: Text(
                              'رفض ومغادرة (Decline)',
                              style: GoogleFonts.cairo(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.redAccent),
                            ),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Colors.redAccent, width: 1.2),
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                          ElevatedButton.icon(
                            onPressed: _voteReadyForNextRound,
                            icon: const Icon(Icons.thumb_up, size: 20),
                            label: Text(
                              '👍 أنا جاهز للدور التالي',
                              style: GoogleFonts.cairo(fontSize: 14, fontWeight: FontWeight.bold),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2E7D32),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ],
                      )
                    else ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF140B05),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: const Color(0xFF81C784), width: 1.2),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 15,
                              height: 15,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF81C784)),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'أنت جاهز ✅ — بانتظار باقي اللاعبين ($approvedCount/$totalHumanPlayers)...',
                              style: GoogleFonts.cairo(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: const Color(0xFF81C784),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _leaveRoom,
                        icon: const Icon(Icons.exit_to_app, size: 15, color: Colors.redAccent),
                        label: Text(
                          'تراجع ومغادرة الغرفة (Decline)',
                          style: GoogleFonts.cairo(fontSize: 11.5, color: Colors.redAccent),
                        ),
                      ),
                    ],
                    if (_isRoomCreator) ...[
                      const SizedBox(height: 8),
                      TextButton.icon(
                        onPressed: _requestNextOnlineRound,
                        icon: const Icon(Icons.fast_forward, size: 16, color: Color(0xFFD4AF37)),
                        label: Text(
                          'تخطي الانتظار وبدء الدور فوراً (خاص بالأدمن 👑)',
                          style: GoogleFonts.cairo(fontSize: 11.5, color: const Color(0xFFD4AF37), fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ] else
                    ElevatedButton(
                      onPressed: () {
                        setState(() {
                          _controller.startRound();
                          _selectedTile = null;
                          _resetLocalTurnTimer();
                        });
                        if (_gameMode == GameMode.vsComputer) _checkBotTurn();
                        _checkAndTriggerTurnVibration();
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFD4AF37),
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 10),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      child: Text(
                        'الدور التالي',
                        style: GoogleFonts.cairo(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
