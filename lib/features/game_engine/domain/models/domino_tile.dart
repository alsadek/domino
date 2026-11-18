/// Standard Domino Tile (Double-Six)
class DominoTile {
  final int head; // First side
  final int tail; // Second side
  final int id;

  const DominoTile(this.head, this.tail, {required this.id})
      : assert(head >= 0 && head <= 6),
        assert(tail >= 0 && tail <= 6);

  bool get isDouble => head == tail;
  int get pipSum => head + tail;

  /// Returns a new tile flipped
  DominoTile flipped() => DominoTile(tail, head, id: id);

  /// Checks if tile has a specific pip value
  bool hasPip(int value) => head == value || tail == value;

  /// Egyptian Café Pip Names (أسماء النقط الشعبية المصرية)
  static String pipName(int value) {
    switch (value) {
      case 0: return 'بلاط';
      case 1: return 'يك';
      case 2: return 'دو';
      case 3: return 'سيه';
      case 4: return 'جهار';
      case 5: return 'بيش';
      case 6: return 'شيش';
      default: return '$value';
    }
  }

  /// Egyptian Name for the tile (e.g. دوستة، شيش دبش إلخ)
  String get egyptianName {
    if (isDouble) {
      switch (head) {
        case 6: return 'دش (٦-٦)';
        case 5: return 'دبش (٥-٥)';
        case 4: return 'دربي (٤-٤)';
        case 3: return 'دوسه (٣-٣)';
        case 2: return 'دوبارة (٢-٢)';
        case 1: return 'دوبل (١-١)';
        case 0: return 'بلاط (٠-٠)';
      }
    }
    final higher = head > tail ? head : tail;
    final lower = head > tail ? tail : head;
    return '${pipName(higher)} ${pipName(lower)} ($higher-$lower)';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DominoTile &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => '[$head|$tail]';
}
