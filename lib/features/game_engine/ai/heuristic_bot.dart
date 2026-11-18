import '../domain/models/domino_tile.dart';
import '../domain/models/open_end.dart';
import '../domain/rules/game_board.dart';

class HeuristicBot {
  /// Evaluates the hand and board to pick the best strategic move
  static BotDecision decideMove({
    required List<DominoTile> hand,
    required GameBoard board,
    required bool boneyardHasTiles,
  }) {
    if (board.isEmpty) {
      // Opening move on empty board:
      // Must be a double (بفّة)! If bot holds doubles, play highest double.
      final doubles = hand.where((t) => t.isDouble).toList();

      if (doubles.isNotEmpty) {
        doubles.sort((a, b) => b.pipSum.compareTo(a.pipSum));
        return BotDecision.play(tile: doubles.first, targetEnd: null);
      } else {
        // Must pass if holding no double on opening move!
        return BotDecision.pass();
      }
    }

    // Find all legal candidate moves
    MoveCandidate? bestCandidate;
    int highestScore = -99999;

    for (final tile in hand) {
      final legalEnds = board.findLegalPlacements(tile);

      for (final end in legalEnds) {
        final evaluation = _evaluateCandidate(
          tile: tile,
          end: end,
          hand: hand,
          board: board,
        );

        if (evaluation > highestScore) {
          highestScore = evaluation;
          bestCandidate = MoveCandidate(
            tile: tile,
            end: end,
            evaluation: evaluation,
          );
        }
      }
    }

    if (bestCandidate != null) {
      return BotDecision.play(
        tile: bestCandidate.tile,
        targetEnd: bestCandidate.end,
      );
    }

    // No legal moves
    if (boneyardHasTiles) {
      return BotDecision.draw();
    } else {
      return BotDecision.pass();
    }
  }

  static int _evaluateCandidate({
    required DominoTile tile,
    required OpenEnd end,
    required List<DominoTile> hand,
    required GameBoard board,
  }) {
    // 1. Calculate projected open ends without mutating actual board
    final connectPip = end.exposedPip;
    final outerPip = (tile.head == connectPip) ? tile.tail : tile.head;

    final immediatePoints = board.calculateProjectedScore(end, tile);

    int heuristic = 0;

    // A. Highest priority: IMMEDIATE POINTS (x100 weight)
    heuristic += immediatePoints * 100;

    // B. High-pip dump: getting rid of heavy tiles reduces risk on lock
    heuristic += tile.pipSum * 3;

    // C. Hand synergy: prefer leaving an exposed end that matches remaining tiles
    final remainingHand = hand.where((t) => t.id != tile.id);
    final synergy = remainingHand.where((t) => t.hasPip(outerPip)).length;
    heuristic += synergy * 10;

    // D. Preserve doubles if they don't score
    if (tile.isDouble && immediatePoints == 0) {
      heuristic -= 10;
    }

    return heuristic;
  }
}

enum BotActionType { play, draw, pass }

class BotDecision {
  final BotActionType action;
  final DominoTile? tile;
  final OpenEnd? targetEnd;

  const BotDecision._({required this.action, this.tile, this.targetEnd});

  factory BotDecision.play({
    required DominoTile tile,
    required OpenEnd? targetEnd,
  }) {
    return BotDecision._(
      action: BotActionType.play,
      tile: tile,
      targetEnd: targetEnd,
    );
  }

  factory BotDecision.draw() =>
      const BotDecision._(action: BotActionType.draw);

  factory BotDecision.pass() =>
      const BotDecision._(action: BotActionType.pass);
}

class MoveCandidate {
  final DominoTile tile;
  final OpenEnd end;
  final int evaluation;

  const MoveCandidate({
    required this.tile,
    required this.end,
    required this.evaluation,
  });
}
