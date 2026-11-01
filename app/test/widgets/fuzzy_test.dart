import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/widgets/common.dart';

void main() {
  test('fuzzyMatch forgives spacing, punctuation and skipped letters', () {
    expect(fuzzyMatch('卫宫饭', '卫宫家今天的饭 (2018)'), isTrue);
    expect(fuzzyMatch('akujodewa', 'Futsutsuka na Akujo de wa'), isTrue);
    expect(fuzzyMatch('metal panic', 'Full.Metal.Panic!.S01E01.mkv'), isTrue);
    expect(fuzzyMatch('Panic Metal', 'Full Metal Panic'), isTrue);
    expect(fuzzyMatch('xyz', 'Full Metal Panic'), isFalse);
    expect(fuzzyMatch('fp', 'Full Metal Panic'), isFalse); // too short to skip
  });
}
