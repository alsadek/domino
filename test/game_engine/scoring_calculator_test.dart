import 'package:test/test.dart';
import 'package:domino_masri/features/game_engine/domain/rules/tile_set.dart';
import 'package:domino_masri/features/game_engine/domain/rules/scoring_calculator.dart';
import 'package:domino_masri/features/game_engine/domain/models/domino_tile.dart';

void main() {
  group('TileSet Tests', () {
    test('Generates standard 28 double-six dominoes', () {
      final set = TileSet.generateDoubleSix();
      expect(set.length, 28);

      // Check all combinations (0,0) to (6,6)
      for (int i = 0; i <= 6; i++) {
        for (int j = i; j <= 6; j++) {
          final found = set.any((t) =>
              (t.head == i && t.tail == j) || (t.head == j && t.tail == i));
          expect(found, isTrue, reason: 'Tile [$i|$j] must exist in the set');
        }
      }
    });

    test('Deals 7 tiles to 2 players with 14 in boneyard (السحاب)', () {
      final deal = TileSet.deal(playerCount: 2, tilesPerPlayer: 7);
      expect(deal.hands.length, 2);
      expect(deal.hands[0].length, 7);
      expect(deal.hands[1].length, 7);
      expect(deal.boneyard.length, 14);

      // Ensure no duplicate tiles across hands and boneyard
      final allDealtIds = [
        ...deal.hands[0].map((t) => t.id),
        ...deal.hands[1].map((t) => t.id),
        ...deal.boneyard.map((t) => t.id),
      ];
      expect(allDealtIds.toSet().length, 28);
    });
  });

  group('ScoringCalculator - Egyptian Pip-to-Point Rule', () {
    test('Rounds down to complete multiples of 5', () {
      expect(ScoringCalculator.roundToNearestFive(0), 0);
      expect(ScoringCalculator.roundToNearestFive(1), 0);
      expect(ScoringCalculator.roundToNearestFive(2), 0);
      expect(ScoringCalculator.roundToNearestFive(3), 0);
      expect(ScoringCalculator.roundToNearestFive(4), 0);
      expect(ScoringCalculator.roundToNearestFive(5), 5);
      expect(ScoringCalculator.roundToNearestFive(6), 5);
      expect(ScoringCalculator.roundToNearestFive(7), 5);
      expect(ScoringCalculator.roundToNearestFive(8), 5);
      expect(ScoringCalculator.roundToNearestFive(9), 5);
      expect(ScoringCalculator.roundToNearestFive(10), 10);
      expect(ScoringCalculator.roundToNearestFive(11), 10);
      expect(ScoringCalculator.roundToNearestFive(12), 10);
      expect(ScoringCalculator.roundToNearestFive(13), 10);
      expect(ScoringCalculator.roundToNearestFive(14), 10);
      expect(ScoringCalculator.roundToNearestFive(15), 15);
      expect(ScoringCalculator.roundToNearestFive(27), 25);
      expect(ScoringCalculator.roundToNearestFive(28), 25);
    });

    test('pipsToPoints divides complete 5s and drops remainder', () {
      expect(ScoringCalculator.pipsToPoints(0), 0);
      expect(ScoringCalculator.pipsToPoints(2), 0);
      expect(ScoringCalculator.pipsToPoints(4), 0);
      expect(ScoringCalculator.pipsToPoints(5), 1);
      expect(ScoringCalculator.pipsToPoints(9), 1);
      expect(ScoringCalculator.pipsToPoints(10), 2);
      expect(ScoringCalculator.pipsToPoints(14), 2); // 14 pips = 2 points only!
      expect(ScoringCalculator.pipsToPoints(15), 3);
      expect(ScoringCalculator.pipsToPoints(20), 4);
      expect(ScoringCalculator.pipsToPoints(22), 4);
      expect(ScoringCalculator.pipsToPoints(23), 4);
      expect(ScoringCalculator.pipsToPoints(25), 5);
    });

    test('Takhlees score awards 1 point per 5 pips and drops remainder', () {
      // Hand with [6|6] (12) + [1|0] (1) = 13 pips -> 13 ~/ 5 = 2 points
      final loserHand = [
        const DominoTile(6, 6, id: 0),
        const DominoTile(1, 0, id: 1),
      ];
      expect(ScoringCalculator.calculateTakhleesScore(loserHand), 2);

      // Hand with 14 pips -> 14 ~/ 5 = 2 points
      final hand14 = [
        const DominoTile(6, 4, id: 3), // 10
        const DominoTile(3, 1, id: 4), // 4
      ];
      expect(ScoringCalculator.calculateTakhleesScore(hand14), 2);

      // Hand with [1|1] (2) -> 0 points
      final tinyHand = [const DominoTile(1, 1, id: 2)];
      expect(ScoringCalculator.calculateTakhleesScore(tinyHand), 0);
    });

    test('Lock calculation awards difference divided by 5', () {
      // Player hand: [1|1] = 2 pips
      // Opponent hand: [6|6] (12) + [3|0] (3) = 15 pips
      // Difference: 15 - 2 = 13 pips -> 13 ~/ 5 = 2 points
      final result = ScoringCalculator.calculateLockScore(
        playerHand: [const DominoTile(1, 1, id: 0)],
        opponentHand: [
          const DominoTile(6, 6, id: 1),
          const DominoTile(3, 0, id: 2),
        ],
      );

      expect(result.winnerIndex, 0);
      expect(result.awardedPoints, 2);
      expect(result.playerPips, 2);
      expect(result.opponentPips, 15);
    });
  });
}
