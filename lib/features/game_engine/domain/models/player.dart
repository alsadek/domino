import 'domino_tile.dart';

class Player {
  final int id;
  final String name;
  final bool isAi;
  final List<DominoTile> hand;
  final int score;

  const Player({
    required this.id,
    required this.name,
    this.isAi = false,
    this.hand = const [],
    this.score = 0,
  });

  int get remainingPips => hand.fold(0, (sum, tile) => sum + tile.pipSum);
  bool get hasDominoed => hand.isEmpty;

  Player copyWith({
    List<DominoTile>? hand,
    int? score,
    String? name,
    bool? isAi,
  }) {
    return Player(
      id: id,
      name: name ?? this.name,
      isAi: isAi ?? this.isAi,
      hand: hand ?? this.hand,
      score: score ?? this.score,
    );
  }
}
