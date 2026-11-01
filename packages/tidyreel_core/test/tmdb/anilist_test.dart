import 'package:test/test.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  test('parseAniList keeps native, english, romaji, synonyms once each', () {
    final titles = parseAniList([
      {
        'title': {
          'native': '不束者な悪女ですが',
          'english': null,
          'romaji': 'Futsutsuka na Akujo dewa Gozaimasu ga',
        },
        'synonyms': ['恶女不才', 'Futsutsuka na Akujo dewa Gozaimasu ga'],
      },
    ]);
    expect(titles, [
      '不束者な悪女ですが',
      'Futsutsuka na Akujo dewa Gozaimasu ga',
      '恶女不才',
    ]);
  });

  test('subtitles are also tried without, and plausibility ignores spaces', () {
    final m = {
      'title': {
        'native': 'ふつつかな悪女ではございますが ~雛宮蝶鼠とりかえ伝~',
        'romaji':
            'Futsutsuka na Akujo de wa Gozaimasu ga: Suuguu Chouso Torikae Den',
      },
    };
    expect(parseAniList([m]), contains('ふつつかな悪女ではございますが'));
    expect(
      plausibleAniList('Futsutsuka na Akujo dewa Gozaimasu ga', m),
      isTrue,
    );
    expect(plausibleAniList('Futsutsuka na Shounen', m), isFalse);
  });
}
