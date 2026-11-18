import 'models/domino_tile.dart';
import 'models/player.dart';
import 'rules/game_board.dart';

enum RoundEndReason {
  domino, // نزول كل الورق (تخليص)
  locked, // قفلة (البلوك)
}

class GameState {
  final GameBoard board;
  final List<Player> players;
  final List<DominoTile> boneyard;
  final int activePlayerIndex;
  final int roundNumber;
  final int targetScore;
  final bool isRoundOver;
  final bool isGameOver;
  final int? roundWinnerIndex;
  final int? gameWinnerIndex;
  final RoundEndReason? roundEndReason;
  final int lastPointsScored;
  final String lastActionBanner;

  const GameState({
    required this.board,
    required this.players,
    required this.boneyard,
    required this.activePlayerIndex,
    required this.roundNumber,
    required this.targetScore,
    this.isRoundOver = false,
    this.isGameOver = false,
    this.roundWinnerIndex,
    this.gameWinnerIndex,
    this.roundEndReason,
    this.lastPointsScored = 0,
    this.lastActionBanner = '',
  });

  Player get activePlayer => players[activePlayerIndex];
  Player get opponentPlayer => players[1 - activePlayerIndex];

  GameState copyWith({
    GameBoard? board,
    List<Player>? players,
    List<DominoTile>? boneyard,
    int? activePlayerIndex,
    int? roundNumber,
    int? targetScore,
    bool? isRoundOver,
    bool? isGameOver,
    int? roundWinnerIndex,
    int? gameWinnerIndex,
    RoundEndReason? roundEndReason,
    int? lastPointsScored,
    String? lastActionBanner,
  }) {
    return GameState(
      board: board ?? this.board,
      players: players ?? this.players,
      boneyard: boneyard ?? this.boneyard,
      activePlayerIndex: activePlayerIndex ?? this.activePlayerIndex,
      roundNumber: roundNumber ?? this.roundNumber,
      targetScore: targetScore ?? this.targetScore,
      isRoundOver: isRoundOver ?? this.isRoundOver,
      isGameOver: isGameOver ?? this.isGameOver,
      roundWinnerIndex: roundWinnerIndex ?? this.roundWinnerIndex,
      gameWinnerIndex: gameWinnerIndex ?? this.gameWinnerIndex,
      roundEndReason: roundEndReason ?? this.roundEndReason,
      lastPointsScored: lastPointsScored ?? this.lastPointsScored,
      lastActionBanner: lastActionBanner ?? this.lastActionBanner,
    );
  }
}
