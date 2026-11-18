import 'dart:math';
import '../game_state.dart';
import '../models/domino_tile.dart';
import '../models/open_end.dart';
import '../models/player.dart';
import 'game_board.dart';
import 'scoring_calculator.dart';
import 'tile_set.dart';

class GameController {
  late GameState state;
  final Random? _random;

  GameController({Random? random}) : _random = random;

  void setTargetScore(int newTargetScore) {
    final safeTarget = newTargetScore < 1 ? 31 : newTargetScore;
    final anyWinner = state.players.indexWhere((p) => p.score >= safeTarget);
    state = state.copyWith(
      targetScore: safeTarget,
      isGameOver: state.isRoundOver && anyWinner != -1,
      gameWinnerIndex: (state.isRoundOver && anyWinner != -1) ? anyWinner : null,
    );
  }

  /// Initializes and starts a new match for 2 to 4 players
  void startMatch({
    int playerCount = 4,
    List<String>? playerNames,
    bool vsAi = false,
    int targetScore = 31,
  }) {
    final names = playerNames ?? List.generate(playerCount, (i) => 'لاعب ${i + 1}');
    final playersList = List.generate(playerCount, (i) {
      return Player(
        id: i,
        name: names[i],
        isAi: vsAi && i != 0,
        score: 0,
      );
    });

    state = GameState(
      board: GameBoard(),
      players: playersList,
      boneyard: [],
      activePlayerIndex: 0,
      roundNumber: 0,
      targetScore: targetScore,
      isRoundOver: false,
      isGameOver: false,
    );

    startRound();
  }

  /// Starts a match with an authoritative server-synchronized deal (Online Multiplayer)
  void startMatchWithDeal({
    required List<List<DominoTile>> hands,
    required List<DominoTile> boneyard,
    required int startingPlayerIndex,
    List<String>? playerNames,
    List<bool>? isAiList,
    int targetScore = 31,
  }) {
    final playerCount = hands.length;
    final names = playerNames ?? List.generate(playerCount, (i) => 'لاعب ${i + 1}');

    final playersList = List.generate(playerCount, (i) {
      return Player(
        id: i,
        name: names[i],
        isAi: (isAiList != null && i < isAiList.length) ? isAiList[i] : false,
        score: 0,
        hand: hands[i],
      );
    });

    state = GameState(
      board: GameBoard(),
      players: playersList,
      boneyard: boneyard,
      activePlayerIndex: startingPlayerIndex,
      roundNumber: 1,
      targetScore: targetScore,
      isRoundOver: false,
      isGameOver: false,
      lastActionBanner: 'بدأ الجيم: دور ${names[startingPlayerIndex]} بالدوش!',
    );
  }

  /// Updates player names and AI flags dynamically when remote players join or replace bots
  void updatePlayerNames(List<String> names, {List<bool>? isAiList}) {
    final updated = List<Player>.from(state.players);
    for (int i = 0; i < names.length && i < updated.length; i++) {
      final name = names[i].trim();
      final ai = (isAiList != null && i < isAiList.length) ? isAiList[i] : null;
      if (name.isNotEmpty || ai != null) {
        updated[i] = updated[i].copyWith(
          name: name.isNotEmpty ? name : null,
          isAi: ai,
        );
      }
    }
    state = state.copyWith(players: updated);
  }

  /// Starts a new round
  void startRound() {
    final pCount = state.players.length;
    final tilesPerPlayer = (pCount == 4) ? 7 : (pCount == 3 ? 7 : 7);

    final deal = TileSet.deal(
      playerCount: pCount,
      tilesPerPlayer: tilesPerPlayer,
      random: _random,
    );

    final nextRoundNumber = state.roundNumber + 1;
    final newBoard = GameBoard();

    int startingPlayerIndex;

    if (nextRoundNumber == 1) {
      // First round: Player with highest double leads
      startingPlayerIndex = _findHighestDoubleHolder(deal.hands);
    } else {
      // Subsequent rounds: Winner of previous round leads
      startingPlayerIndex = state.roundWinnerIndex ?? 0;
    }

    final updatedPlayers = List.generate(pCount, (i) {
      return state.players[i].copyWith(hand: deal.hands[i]);
    });

    state = state.copyWith(
      board: newBoard,
      players: updatedPlayers,
      boneyard: deal.boneyard,
      activePlayerIndex: startingPlayerIndex,
      roundNumber: nextRoundNumber,
      isRoundOver: false,
      roundWinnerIndex: null,
      roundEndReason: null,
      lastPointsScored: 0,
      lastActionBanner: 'بدأ الدور $nextRoundNumber: دور ${updatedPlayers[startingPlayerIndex].name} بالدوش!',
    );
  }

  /// Starts next round with authoritative deal from server (Online Multiplayer)
  void startNextRoundWithDeal({
    required List<List<DominoTile>> hands,
    required List<DominoTile> boneyard,
    required int startingPlayerIndex,
  }) {
    final nextRoundNumber = state.roundNumber + 1;
    final newBoard = GameBoard();

    final updatedPlayers = List.generate(state.players.length, (i) {
      return state.players[i].copyWith(hand: hands[i]);
    });

    state = state.copyWith(
      board: newBoard,
      players: updatedPlayers,
      boneyard: boneyard,
      activePlayerIndex: startingPlayerIndex,
      roundNumber: nextRoundNumber,
      isRoundOver: false,
      roundWinnerIndex: null,
      roundEndReason: null,
      lastPointsScored: 0,
      lastActionBanner: 'بدأ الدور $nextRoundNumber: دور ${updatedPlayers[startingPlayerIndex].name} بالبفّة!',
    );
  }

  bool hasLegalMove(int playerIndex) {
    if (playerIndex >= state.players.length) return false;
    final player = state.players[playerIndex];
    if (state.board.isEmpty) {
      // Opening tile (الفتحة) MUST be a double (بفّة / دوش)
      // If player holds no double, they must pass!
      return player.hand.any((t) => t.isDouble);
    }

    for (final tile in player.hand) {
      if (state.board.findLegalPlacements(tile).isNotEmpty) {
        return true;
      }
    }
    return false;
  }

  void playTile({
    required int playerIndex,
    required DominoTile tile,
    OpenEnd? targetEnd,
  }) {
    assert(playerIndex == state.activePlayerIndex, 'Not this player\'s turn');
    assert(!state.isRoundOver, 'Round is already over');

    final player = state.players[playerIndex];
    assert(player.hand.contains(tile), 'Player does not hold this tile');

    // 1. Place tile on the board
    if (state.board.isEmpty) {
      if (!tile.isDouble) {
        throw ArgumentError('الفتحة لازم تكون بفة (ورقة بنفس القيمة من الطرفين)');
      }
      state.board.placeFirstTile(tile);
    } else {
      assert(targetEnd != null, 'targetEnd required when board is not empty');
      state.board.playTile(tile: tile, targetEnd: targetEnd!);
    }

    // 2. Remove tile from hand
    final newHand = List<DominoTile>.from(player.hand)..remove(tile);

    // 3. Calculate live board score (Multiples of 5 only after cross is complete)
    final pointsScored = ScoringCalculator.evaluateBoardScore(state.board.getScoringEnds());
    final newTotalScore = player.score + pointsScored;

    final updatedPlayer = player.copyWith(
      hand: newHand,
      score: newTotalScore,
    );

    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIndex] = updatedPlayer;

    String banner = pointsScored > 0
        ? '${player.name} سجّل $pointsScored نقطة! (${tile.egyptianName})'
        : 'لعب ${player.name}: ${tile.egyptianName}';

    state = state.copyWith(
      players: updatedPlayers,
      lastPointsScored: pointsScored,
      lastActionBanner: banner,
    );

    // 4. Check for Domino (تخليص)
    if (newHand.isEmpty) {
      _handleDominoWin(winnerIndex: playerIndex);
      return;
    }

    // 5. Check for Lock (قفلة) across all players
    final boneyardEmpty = state.boneyard.isEmpty;
    final allBlocked = boneyardEmpty &&
        List.generate(state.players.length, (i) => i).every((i) => !hasLegalMove(i));

    if (allBlocked) {
      _handleLockWin();
      return;
    }

    // 6. Advance turn to next player in circular order
    final nextIndex = (playerIndex + 1) % state.players.length;
    state = state.copyWith(activePlayerIndex: nextIndex);
  }

  DominoTile? drawTile(int playerIndex) {
    assert(playerIndex == state.activePlayerIndex, 'Not this player\'s turn');
    assert(state.boneyard.isNotEmpty, 'Boneyard is empty');

    final newBoneyard = List<DominoTile>.from(state.boneyard);
    final drawn = newBoneyard.removeLast();

    final player = state.players[playerIndex];
    final updatedPlayer = player.copyWith(
      hand: [...player.hand, drawn],
    );

    final updatedPlayers = List<Player>.from(state.players);
    updatedPlayers[playerIndex] = updatedPlayer;

    state = state.copyWith(
      players: updatedPlayers,
      boneyard: newBoneyard,
      lastActionBanner: '${player.name} سحب من السحّاب',
      lastPointsScored: 0,
    );

    return drawn;
  }

  void passTurn(int playerIndex) {
    assert(playerIndex == state.activePlayerIndex, 'Not this player\'s turn');
    assert(!hasLegalMove(playerIndex), 'Cannot pass with legal moves available');
    assert(state.boneyard.isEmpty, 'Cannot pass while boneyard has tiles');

    final nextIndex = (playerIndex + 1) % state.players.length;

    // Check if all players are blocked (Lock)
    final allBlocked = List.generate(state.players.length, (i) => i).every((i) => !hasLegalMove(i));
    if (allBlocked) {
      _handleLockWin();
      return;
    }

    final banner = state.board.isEmpty
        ? '${state.players[playerIndex].name} معهوش بفّة وباصى! دور ${state.players[nextIndex].name} للفتحة'
        : '${state.players[playerIndex].name} قال باص!';

    state = state.copyWith(
      activePlayerIndex: nextIndex,
      lastActionBanner: banner,
      lastPointsScored: 0,
    );
  }

  void _handleDominoWin({required int winnerIndex}) {
    _finishRoundWithHandDeductions(
      winnerIndex: winnerIndex,
      reason: RoundEndReason.domino,
    );
  }

  void _handleLockWin() {
    // Find player with lowest remaining pips
    int minPips = 9999;
    int? winnerIdx;
    bool isTie = false;

    for (int i = 0; i < state.players.length; i++) {
      final pips = state.players[i].hand.fold<int>(0, (sum, t) => sum + t.pipSum);
      if (pips < minPips) {
        minPips = pips;
        winnerIdx = i;
        isTie = false;
      } else if (pips == minPips) {
        isTie = true;
      }
    }

    _finishRoundWithHandDeductions(
      winnerIndex: isTie ? null : winnerIdx,
      reason: RoundEndReason.locked,
      customTieBanner: '🔒 قفلت تعادل! محدش أخد أو اتخصم منه نقط.',
    );
  }

  /// Deducts each losing player's remaining hand (pips rounded to 5 and divided by 5)
  /// from their own score without awarding opponent hand points to the round winner.
  void _finishRoundWithHandDeductions({
    required int? winnerIndex,
    required RoundEndReason reason,
    String? customTieBanner,
  }) {
    final updatedPlayers = List<Player>.from(state.players);
    final deductionParts = <String>[];

    if (winnerIndex != null) {
      for (int p = 0; p < updatedPlayers.length; p++) {
        if (p == winnerIndex) continue;
        final player = updatedPlayers[p];
        final rawPips = player.hand.fold<int>(0, (sum, t) => sum + t.pipSum);
        final penalty = ScoringCalculator.pipsToPoints(rawPips);
        updatedPlayers[p] = player.copyWith(score: player.score - penalty);
        deductionParts.add('${player.name}: -$penalty ($rawPips بنط)');
      }
    }

    int? gameWinnerIdx;
    int bestScore = state.targetScore - 1;
    for (int p = 0; p < updatedPlayers.length; p++) {
      final s = updatedPlayers[p].score;
      if (s >= state.targetScore) {
        if (gameWinnerIdx == null ||
            s > bestScore ||
            (s == bestScore && p == winnerIndex)) {
          bestScore = s;
          gameWinnerIdx = p;
        }
      }
    }

    final isGameOver = gameWinnerIdx != null;
    String banner;
    if (isGameOver) {
      final champ = updatedPlayers[gameWinnerIdx];
      banner = '🏆 مبروك! فاز ${champ.name} بالبولة بمجموع ${champ.score} نقطة!';
    } else if (winnerIndex != null) {
      final roundWinner = updatedPlayers[winnerIndex];
      final prefix = reason == RoundEndReason.domino
          ? 'ضمن ${roundWinner.name}!'
          : '🔒 قفلت! كسب ${roundWinner.name} الدور!';
      banner = prefix;
    } else {
      banner = customTieBanner ?? '🔒 قفلت تعادل! محدش أخد أو اتخصم منه نقط.';
    }

    state = state.copyWith(
      players: updatedPlayers,
      isRoundOver: true,
      roundWinnerIndex: winnerIndex,
      roundEndReason: reason,
      isGameOver: isGameOver,
      gameWinnerIndex: gameWinnerIdx,
      lastPointsScored: 0,
      lastActionBanner: banner,
    );
  }

  int _findHighestDoubleHolder(List<List<DominoTile>> hands) {
    for (int doublePip = 6; doublePip >= 0; doublePip--) {
      for (int p = 0; p < hands.length; p++) {
        if (hands[p].any((t) => t.isDouble && t.head == doublePip)) {
          return p;
        }
      }
    }
    int maxPips = -1;
    int starter = 0;
    for (int p = 0; p < hands.length; p++) {
      for (final t in hands[p]) {
        if (t.pipSum > maxPips) {
          maxPips = t.pipSum;
          starter = p;
        }
      }
    }
    return starter;
  }
}
