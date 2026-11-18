import 'package:test/test.dart';
import 'package:domino_masri/features/game_engine/domain/models/board_node.dart';
import 'package:domino_masri/features/game_engine/domain/models/direction.dart';
import 'package:domino_masri/features/game_engine/domain/models/domino_tile.dart';
import 'package:domino_masri/features/game_engine/domain/rules/game_board.dart';
import 'package:domino_masri/features/game_engine/domain/rules/scoring_calculator.dart';

void main() {
  group('GameBoard & Egyptian Domino 4-Arm Spinner Rules', () {
    test('Opening with [5|5] (دبش) scores 0 points because spinner is not fully crossed yet', () {
      final board = GameBoard();
      const tile55 = DominoTile(5, 5, id: 0);

      board.placeFirstTile(tile55);

      expect(board.hasSpinner, isTrue);
      expect(board.openEnds.length, 4); // East, West, North, South
      expect(board.isSpinnerFullyCrossed, isFalse);

      // Egyptian Rule: Calculation does NOT start until all 4 sides have cards played!
      final score = ScoringCalculator.evaluateBoardScore(board.getScoringEnds());
      expect(score, 0);
    });

    test('No branch extension allowed until all four arms of the spinner are played', () {
      final board = GameBoard();
      const spinner = DominoTile(6, 6, id: 0);
      board.placeFirstTile(spinner);

      expect(board.openEnds.length, 4); // 4 open sides of spinner

      // 1. Play [6|0] on East
      final east = board.openEnds.firstWhere((e) => e.attachDirection == Direction.east);
      board.playTile(tile: const DominoTile(6, 0, id: 1), targetEnd: east);
      // Spinner is NOT fully crossed yet (3 sides remaining: West, North, South)
      expect(board.isSpinnerFullyCrossed, isFalse);
      expect(board.openEnds.length, 3); // ONLY the remaining spinner arms can be played!

      // 2. Play [6|4] on West
      final west = board.openEnds.firstWhere((e) => e.attachDirection == Direction.west);
      board.playTile(tile: const DominoTile(6, 4, id: 2), targetEnd: west);
      expect(board.isSpinnerFullyCrossed, isFalse);
      expect(board.openEnds.length, 2); // North and South remaining on spinner

      // 3. Play [6|5] on North
      final north = board.openEnds.firstWhere((e) => e.attachDirection == Direction.north);
      board.playTile(tile: const DominoTile(6, 5, id: 3), targetEnd: north);
      expect(board.isSpinnerFullyCrossed, isFalse);
      expect(board.openEnds.length, 1); // Only South remaining on spinner

      // 4. Play [6|1] on South (The 4th side!)
      final south = board.openEnds.firstWhere((e) => e.attachDirection == Direction.south);
      board.playTile(tile: const DominoTile(6, 1, id: 4), targetEnd: south);

      // NOW all 4 sides are filled! Spinner is fully crossed!
      expect(board.isSpinnerFullyCrossed, isTrue);

      // Now all 4 branch ends are unlocked for future plays!
      expect(board.openEnds.length, 4);
      final exposedPips = board.openEnds.map((e) => e.exposedPip).toSet();
      expect(exposedPips, containsAll([0, 4, 5, 1]));

      // 5. Subsequent move: extend East branch with [0|5]
      final eastLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.east);
      board.playTile(tile: const DominoTile(0, 5, id: 5), targetEnd: eastLeaf);

      // Current ends: East (5), West (4), North (5), South (1) = 15 pips -> 15 / 5 = 3 points!
      final score = ScoringCalculator.evaluateBoardScore(board.getScoringEnds());
      expect(score, 3);
    });

    test('North branch turns East after 1 tile, South turns West after 1 tile', () {
      final board = GameBoard();
      const spinner = DominoTile(6, 6, id: 0);
      board.placeFirstTile(spinner);

      // Complete cross (Tile 1 on each of East, West, North, South)
      board.playTile(tile: const DominoTile(6, 0, id: 1), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.east));
      board.playTile(tile: const DominoTile(6, 4, id: 2), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.west));
      board.playTile(tile: const DominoTile(6, 5, id: 3), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.north));
      board.playTile(tile: const DominoTile(6, 1, id: 4), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.south));

      expect(board.isSpinnerFullyCrossed, isTrue);

      // 1. North branch after cross: immediately turns East!
      final northLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.north);
      expect(northLeaf.attachDirection, Direction.east);
      expect(northLeaf.exposedPip, 5);

      // Play [5|2] on North branch (turns East)
      final northTile2 = board.playTile(tile: const DominoTile(5, 2, id: 5), targetEnd: northLeaf);
      expect(northTile2.orientation, TileOrientation.horizontal);
      expect(northTile2.pixelY, -100.0);
      expect(northTile2.pixelX, 60.0);

      // 2. South branch after cross: immediately turns West!
      final southLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.south);
      expect(southLeaf.attachDirection, Direction.west);
      expect(southLeaf.exposedPip, 1);

      // Play [1|3] on South branch (turns West)
      final southTile2 = board.playTile(tile: const DominoTile(1, 3, id: 6), targetEnd: southLeaf);
      expect(southTile2.orientation, TileOrientation.horizontal);
      expect(southTile2.pixelY, 100.0);
      expect(southTile2.pixelX, -60.0);
    });

    test('Horizontal branches (East & West) turn vertically after 5 cards', () {
      final board = GameBoard();
      const spinner = DominoTile(6, 6, id: 0);
      board.placeFirstTile(spinner);

      // Complete cross
      board.playTile(tile: const DominoTile(6, 0, id: 1), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.east));
      board.playTile(tile: const DominoTile(6, 4, id: 2), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.west));
      board.playTile(tile: const DominoTile(6, 5, id: 3), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.north));
      board.playTile(tile: const DominoTile(6, 1, id: 4), targetEnd: board.openEnds.firstWhere((e) => e.attachDirection == Direction.south));

      // East branch: Tile 1 is [6|0].
      // Play Tile 2: [0|2]
      var eastLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.east);
      expect(eastLeaf.attachDirection, Direction.east);
      board.playTile(tile: const DominoTile(0, 2, id: 5), targetEnd: eastLeaf);

      // Play Tile 3: [2|3]
      eastLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.east);
      expect(eastLeaf.attachDirection, Direction.east);
      board.playTile(tile: const DominoTile(2, 3, id: 6), targetEnd: eastLeaf);

      // Play Tile 4: [3|4]
      eastLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.east);
      expect(eastLeaf.attachDirection, Direction.east);
      board.playTile(tile: const DominoTile(3, 4, id: 7), targetEnd: eastLeaf);

      // Play Tile 5: [4|5]
      eastLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.east);
      expect(eastLeaf.attachDirection, Direction.east);
      final tile5 = board.playTile(tile: const DominoTile(4, 5, id: 8), targetEnd: eastLeaf);
      expect(tile5.orientation, TileOrientation.horizontal);
      expect(tile5.pixelX, 380.0);

      // Now East branch has 5 horizontal cards! Next card (Tile 6) turns South!
      eastLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.east);
      expect(eastLeaf.attachDirection, Direction.south);
      expect(eastLeaf.exposedPip, 5);

      // Play Tile 6: [5|1] - turns South
      final tile6 = board.playTile(tile: const DominoTile(5, 1, id: 9), targetEnd: eastLeaf);
      expect(tile6.orientation, TileOrientation.vertical);
      expect(tile6.pixelX, 400.0);
      expect(tile6.pixelY, 60.0);

      // West branch: Tile 1 is [6|4].
      // Play Tile 2: [4|2]
      var westLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.west);
      expect(westLeaf.attachDirection, Direction.west);
      board.playTile(tile: const DominoTile(4, 2, id: 10), targetEnd: westLeaf);

      // Play Tile 3: [2|1]
      westLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.west);
      expect(westLeaf.attachDirection, Direction.west);
      board.playTile(tile: const DominoTile(2, 1, id: 11), targetEnd: westLeaf);

      // Play Tile 4: [1|5]
      westLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.west);
      expect(westLeaf.attachDirection, Direction.west);
      board.playTile(tile: const DominoTile(1, 5, id: 12), targetEnd: westLeaf);

      // Play Tile 5: [5|3]
      westLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.west);
      expect(westLeaf.attachDirection, Direction.west);
      final westTile5 = board.playTile(tile: const DominoTile(5, 3, id: 13), targetEnd: westLeaf);
      expect(westTile5.orientation, TileOrientation.horizontal);
      expect(westTile5.pixelX, -380.0);

      // Now West branch has 5 horizontal cards! Next card (Tile 6) turns North!
      westLeaf = board.openEnds.firstWhere((e) => e.branch == Direction.west);
      expect(westLeaf.attachDirection, Direction.north);
      expect(westLeaf.exposedPip, 3);

      // Play Tile 6: [3|0] - turns North
      final westTile6 = board.playTile(tile: const DominoTile(3, 0, id: 14), targetEnd: westLeaf);
      expect(westTile6.orientation, TileOrientation.vertical);
      expect(westTile6.pixelX, -400.0);
      expect(westTile6.pixelY, -60.0);
    });
  });
}
