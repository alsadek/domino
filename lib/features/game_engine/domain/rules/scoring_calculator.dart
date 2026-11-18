import '../models/open_end.dart';
import '../models/domino_tile.dart';

class ScoringCalculator {
  /// Evaluates the points scored on a live move.
  /// Every 5 exposed pips equals 1 point (e.g. 5->1, 10->2, 15->3, 20->4).
  /// Returns 0 if the exposed sum is not a multiple of 5.
  static int evaluateBoardScore(List<OpenEnd> openEnds) {
    if (openEnds.isEmpty) return 0;

    int totalPips = 0;
    for (final end in openEnds) {
      totalPips += end.scoringContribution;
    }

    if (totalPips > 0 && totalPips % 5 == 0) {
      return totalPips ~/ 5;
    }
    return 0;
  }

  /// Calculates total exposed pips regardless of whether it's a multiple of 5.
  static int calculateTotalExposedPips(List<OpenEnd> openEnds) {
    int totalPips = 0;
    for (final end in openEnds) {
      totalPips += end.scoringContribution;
    }
    return totalPips;
  }

  /// Egyptian Café Pip-to-Point Rule:
  /// Every 5 pips equals 1 point; fractions less than 5 are dropped ("كل ٥ بنقطة والباقي بيطير").
  /// Examples:
  /// 0..4 pips -> 0 points
  /// 5..9 pips -> 1 point
  /// 10..14 pips -> 2 points (e.g. 14 -> 2 points)
  /// 15..19 pips -> 3 points
  static int roundToNearestFive(int pips) {
    if (pips <= 0) return 0;
    return (pips ~/ 5) * 5;
  }

  /// Converts raw pips to match points by dividing by 5 (each complete 5 = 1 point).
  /// Example: 10..14 pips -> 2 points (14 pips deducts 2 points, not 3).
  static int pipsToPoints(int pips) {
    if (pips <= 0) return 0;
    return pips ~/ 5;
  }

  /// Calculate round-end penalty points from a losing player's remaining hand.
  /// Sum of remaining pips rounded to nearest 5, divided by 5.
  static int calculateTakhleesScore(List<DominoTile> opponentRemainingHand) {
    final rawPips = opponentRemainingHand.fold<int>(
      0,
      (sum, tile) => sum + tile.pipSum,
    );
    return pipsToPoints(rawPips);
  }

  /// Calculate round-end points when the board is locked (قفلت).
  /// The player with fewer pips gets the difference between hands rounded to nearest 5, divided by 5.
  /// Returns a record with the winnerIndex (or null for tie) and points awarded.
  static LockResult calculateLockScore({
    required List<DominoTile> playerHand,
    required List<DominoTile> opponentHand,
  }) {
    final playerPips = playerHand.fold<int>(0, (sum, t) => sum + t.pipSum);
    final opponentPips = opponentHand.fold<int>(0, (sum, t) => sum + t.pipSum);

    if (playerPips < opponentPips) {
      final diff = opponentPips - playerPips;
      return LockResult(
        winnerIndex: 0,
        awardedPoints: pipsToPoints(diff),
        playerPips: playerPips,
        opponentPips: opponentPips,
      );
    } else if (opponentPips < playerPips) {
      final diff = playerPips - opponentPips;
      return LockResult(
        winnerIndex: 1,
        awardedPoints: pipsToPoints(diff),
        playerPips: playerPips,
        opponentPips: opponentPips,
      );
    } else {
      // Tie (تعادل في القفلة)
      return LockResult(
        winnerIndex: null,
        awardedPoints: 0,
        playerPips: playerPips,
        opponentPips: opponentPips,
      );
    }
  }
}

class LockResult {
  final int? winnerIndex; // 0 for player 1, 1 for player 2, null for tie
  final int awardedPoints;
  final int playerPips;
  final int opponentPips;

  const LockResult({
    required this.winnerIndex,
    required this.awardedPoints,
    required this.playerPips,
    required this.opponentPips,
  });
}
