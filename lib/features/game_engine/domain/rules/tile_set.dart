import 'dart:math';
import '../models/domino_tile.dart';

class TileSet {
  /// Generates the standard 28 double-six domino set
  static List<DominoTile> generateDoubleSix() {
    final tiles = <DominoTile>[];
    int id = 0;
    for (int i = 0; i <= 6; i++) {
      for (int j = i; j <= 6; j++) {
        tiles.add(DominoTile(i, j, id: id++));
      }
    }
    return tiles;
  }

  /// Shuffles a list of tiles using an optional random seed (great for tests)
  static List<DominoTile> shuffle(List<DominoTile> tiles, [Random? random]) {
    final shuffled = List<DominoTile>.from(tiles);
    shuffled.shuffle(random ?? Random());
    return shuffled;
  }

  /// Deals tiles to players and returns the remaining boneyard (السحاب)
  /// For 2 players: 7 tiles each, 14 remaining.
  static DealResult deal({
    int playerCount = 2,
    int tilesPerPlayer = 7,
    Random? random,
  }) {
    final fullSet = shuffle(generateDoubleSix(), random);
    final hands = <List<DominoTile>>[];

    int currentIdx = 0;
    for (int p = 0; p < playerCount; p++) {
      hands.add(fullSet.sublist(currentIdx, currentIdx + tilesPerPlayer));
      currentIdx += tilesPerPlayer;
    }

    final boneyard = fullSet.sublist(currentIdx);
    return DealResult(hands: hands, boneyard: boneyard);
  }
}

class DealResult {
  final List<List<DominoTile>> hands;
  final List<DominoTile> boneyard; // السحاب

  DealResult({required this.hands, required this.boneyard});
}
