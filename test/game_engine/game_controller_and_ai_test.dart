import 'package:test/test.dart';
import 'package:domino_masri/features/game_engine/domain/models/direction.dart';
import 'package:domino_masri/features/game_engine/domain/models/domino_tile.dart';
import 'package:domino_masri/features/game_engine/domain/rules/game_board.dart';
import 'package:domino_masri/features/game_engine/domain/rules/game_controller.dart';
import 'package:domino_masri/features/game_engine/ai/heuristic_bot.dart';

void main() {
  group('GameController Tests', () {
    test('Starts match, deals 7 tiles, and highest double player leads round 1', () {
      final controller = GameController();
      controller.startMatch(playerCount: 2, targetScore: 100);

      expect(controller.state.roundNumber, 1);
      expect(controller.state.players[0].hand.length, 7);
      expect(controller.state.players[1].hand.length, 7);
      expect(controller.state.boneyard.length, 14);
      expect(controller.state.isRoundOver, isFalse);
    });

    test('Playing a scoring tile immediately increments player score', () {
      final controller = GameController();
      controller.startMatch(playerCount: 2, targetScore: 100);

      // Force active player's hand to include [5|5] (دبش)
      const tile55 = DominoTile(5, 5, id: 99);
      final activeIdx = controller.state.activePlayerIndex;
      final player = controller.state.players[activeIdx];
      final newHand = [tile55, ...player.hand.sublist(1)];

      controller.state = controller.state.copyWith(
        players: activeIdx == 0
            ? [player.copyWith(hand: newHand), controller.state.players[1]]
            : [controller.state.players[0], player.copyWith(hand: newHand)],
      );

      // Play [5|5]
      controller.playTile(
        playerIndex: activeIdx,
        tile: tile55,
      );

      // In Egyptian American Domino, opening tile gives 0 points because spinner is not fully crossed yet!
      expect(controller.state.players[activeIdx].score, 0);
      expect(controller.state.lastPointsScored, 0);
      // Turn advances to opponent
      expect(controller.state.activePlayerIndex, 1 - activeIdx);
    });

    test('If active player has no double to open, hasLegalMove is false and pass advances turn', () {
      final controller = GameController();
      controller.startMatch(playerCount: 2, targetScore: 100);

      final activeIdx = controller.state.activePlayerIndex;
      // Give active player a hand with NO doubles
      final handNoDoubles = [
        const DominoTile(0, 1, id: 101),
        const DominoTile(1, 2, id: 102),
        const DominoTile(2, 3, id: 103),
      ];

      final p0 = controller.state.players[0];
      final p1 = controller.state.players[1];
      final handWithDouble = [const DominoTile(6, 6, id: 201)];

      controller.state = controller.state.copyWith(
        boneyard: [],
        players: activeIdx == 0
            ? [p0.copyWith(hand: handNoDoubles), p1.copyWith(hand: handWithDouble)]
            : [p0.copyWith(hand: handWithDouble), p1.copyWith(hand: handNoDoubles)],
      );

      // Active player cannot play since opening tile must be a double
      expect(controller.hasLegalMove(activeIdx), isFalse);

      // Passing advances turn to next player
      controller.passTurn(activeIdx);
      expect(controller.state.activePlayerIndex, 1 - activeIdx);
      expect(controller.state.lastActionBanner, contains('معهوش بفّة'));
    });

    test('Round opening strictly requires a double: non-doubles throw ArgumentError, bot passes if no double', () {
      final controller = GameController();
      controller.startMatch(playerCount: 2, targetScore: 100);
      final activeIdx = controller.state.activePlayerIndex;

      final p0 = controller.state.players[0];
      final p1 = controller.state.players[1];
      const nonDouble = DominoTile(2, 4, id: 99);
      const doubleTile = DominoTile(3, 3, id: 88);

      // Player hand with only non-double
      controller.state = controller.state.copyWith(
        boneyard: [],
        players: activeIdx == 0
            ? [p0.copyWith(hand: [nonDouble]), p1.copyWith(hand: [doubleTile])]
            : [p0.copyWith(hand: [doubleTile]), p1.copyWith(hand: [nonDouble])],
      );

      // Attempting to play a non-double on empty board MUST throw ArgumentError
      expect(
        () => controller.playTile(playerIndex: activeIdx, tile: nonDouble),
        throwsA(isA<ArgumentError>()),
      );

      // HeuristicBot on empty board with no double MUST pass
      final botDecision = HeuristicBot.decideMove(
        hand: [nonDouble],
        board: controller.state.board,
        boneyardHasTiles: false,
      );
      expect(botDecision.action, BotActionType.pass);
    });

    test('Domino win deducts remaining hand / 5 from each loser without adding to winner, and respects configurable targetScore', () {
      final controller = GameController();
      // Configurable target score = 4 points
      controller.startMatchWithDeal(
        hands: [
          [const DominoTile(5, 5, id: 0)], // P0 wins round 1 immediately (0 board pts)
          [const DominoTile(6, 4, id: 1)], // 10 pips -> -2 pts
          [const DominoTile(6, 6, id: 2), const DominoTile(4, 4, id: 3)], // 20 pips -> -4 pts
          [const DominoTile(3, 2, id: 4)], // 5 pips -> -1 pt
        ],
        boneyard: [],
        startingPlayerIndex: 0,
        targetScore: 4,
      );

      controller.playTile(playerIndex: 0, tile: const DominoTile(5, 5, id: 0));
      expect(controller.state.isRoundOver, isTrue);
      expect(controller.state.isGameOver, isFalse);
      // Winner gains nothing from opponents' cards; losers have cards / 5 deducted
      expect(controller.state.players[0].score, 0);
      expect(controller.state.players[1].score, -2);
      expect(controller.state.players[2].score, -4);
      expect(controller.state.players[3].score, -1);

      // Round 2: P0 opens [5|5], P1/P2/P3 fill East/West/North, then P0 completes South to score 4 pts and domino
      controller.startNextRoundWithDeal(
        hands: [
          [const DominoTile(5, 5, id: 10), const DominoTile(5, 0, id: 11)], // P0
          [const DominoTile(5, 4, id: 12), const DominoTile(1, 1, id: 15)], // P1
          [const DominoTile(5, 6, id: 13), const DominoTile(2, 2, id: 16)], // P2
          [const DominoTile(5, 5, id: 14), const DominoTile(3, 3, id: 17)], // P3
        ],
        boneyard: [],
        startingPlayerIndex: 0,
      );
      // P0 opens [5|5]
      controller.playTile(playerIndex: 0, tile: const DominoTile(5, 5, id: 10));
      // P1 plays [5|4] on East
      controller.playTile(
        playerIndex: 1,
        tile: const DominoTile(5, 4, id: 12),
        targetEnd: controller.state.board.openEnds.firstWhere((e) => e.attachDirection == Direction.east),
      );
      // P2 plays [5|6] on West
      controller.playTile(
        playerIndex: 2,
        tile: const DominoTile(5, 6, id: 13),
        targetEnd: controller.state.board.openEnds.firstWhere((e) => e.attachDirection == Direction.west),
      );
      // P3 plays [5|5] on North
      controller.playTile(
        playerIndex: 3,
        tile: const DominoTile(5, 5, id: 14),
        targetEnd: controller.state.board.openEnds.firstWhere((e) => e.attachDirection == Direction.north),
      );
      // P0 completes the cross on South with [5|0] -> exposed = 4 + 6 + 10 + 0 = 20 -> +4 points & dominos -> wins Bola!
      controller.playTile(
        playerIndex: 0,
        tile: const DominoTile(5, 0, id: 11),
        targetEnd: controller.state.board.openEnds.firstWhere((e) => e.attachDirection == Direction.south),
      );

      expect(controller.state.roundNumber, 2);
      expect(controller.state.players[0].score, 4);
      // P1: -2 (prior) + [1|1]=2->0 (-2); P2: -4 + [2|2]=4->0 (-4); P3: -1 + [3|3]=6->-1 (-2)
      expect(controller.state.players[1].score, -2);
      expect(controller.state.players[2].score, -4);
      expect(controller.state.players[3].score, -2);
      expect(controller.state.isRoundOver, isTrue);
      expect(controller.state.isGameOver, isTrue);
      expect(controller.state.gameWinnerIndex, 0);
    });

    test('Lock win deducts remaining hand / 5 from losers without adding to lock winner', () {
      final controller = GameController();
      controller.startMatchWithDeal(
        hands: [
          [const DominoTile(6, 6, id: 0), const DominoTile(1, 2, id: 1)], // P0 plays [6|6], keeps [1|2]=3 pips (lowest)
          [const DominoTile(5, 5, id: 2)], // P1 has 10 pips -> -2 pts
          [const DominoTile(4, 3, id: 3)], // P2 has 7 pips -> 7 ~/ 5 = 1 pt -> -1 pt
          [const DominoTile(5, 4, id: 4)], // P3 has 9 pips -> 9 ~/ 5 = 1 pt -> -1 pt
        ],
        boneyard: [],
        startingPlayerIndex: 0,
        targetScore: 31,
      );

      // P0 opens [6|6]; nobody holds a 6 so playTile auto-detects the lock
      controller.playTile(playerIndex: 0, tile: const DominoTile(6, 6, id: 0));

      expect(controller.state.isRoundOver, isTrue);
      expect(controller.state.roundWinnerIndex, 0);
      expect(controller.state.players[0].score, 0);
      expect(controller.state.players[1].score, -2);
      expect(controller.state.players[2].score, -1);
      expect(controller.state.players[3].score, -1);
    });
  });

  group('HeuristicBot AI Tests', () {
    test('AI chooses the move that scores maximum points (multiples of 5) on completing the cross', () {
      final board = GameBoard();
      // Spinner is [5|5]
      board.placeFirstTile(const DominoTile(5, 5, id: 0));

      // Fill 3 arms of spinner:
      // East: [5|1], West: [5|2], North: [5|2]
      final east = board.openEnds.firstWhere((e) => e.attachDirection == Direction.east);
      board.playTile(tile: const DominoTile(5, 1, id: 10), targetEnd: east);

      final west = board.openEnds.firstWhere((e) => e.attachDirection == Direction.west);
      board.playTile(tile: const DominoTile(5, 2, id: 11), targetEnd: west);

      final north = board.openEnds.firstWhere((e) => e.attachDirection == Direction.north);
      board.playTile(tile: const DominoTile(5, 2, id: 12), targetEnd: north);

      // Now only South is open!
      // Bot has two playable tiles for South:
      // Option A: [5|3] -> sum = 1 + 2 + 2 + 3 = 8 (0 points)
      // Option B: [5|0] -> sum = 1 + 2 + 2 + 0 = 5 (5 points!)
      const tileA = DominoTile(5, 3, id: 1);
      const tileB = DominoTile(5, 0, id: 2);
      final hand = [tileA, tileB];

      final decision = HeuristicBot.decideMove(
        hand: hand,
        board: board,
        boneyardHasTiles: true,
      );

      expect(decision.action, BotActionType.play);
      // Bot MUST pick tileB ([5|0]) because it yields 5 points!
      expect(decision.tile?.id, tileB.id);
    });
  });
}
