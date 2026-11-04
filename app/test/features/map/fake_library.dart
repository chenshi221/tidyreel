// A believable media library for map tests and screenshots: a few hundred
// files under /影视库 with deterministic sizes, plus which paths count as
// organized.
import 'dart:math' as math;

const _gb = 1 << 30;
const _mb = 1 << 20;

final _rng = math.Random(7);
int _size(double minGb, double maxGb) =>
    ((minGb + _rng.nextDouble() * (maxGb - minGb)) * _gb).round();

const root = '/影视库';

/// path → size in bytes.
final Map<String, int> fakeLibrary = _build();

/// Paths a done op produced (whole folders count for what's inside).
final Set<String> fakeOrganized = {
  '$root/电影',
  for (final s in ['老友记 (1994)', '绝命毒师 (2008)', '漫长的季节 (2023)', '繁花 (2023)'])
    '$root/剧集/$s',
  for (final s in ['异兽魔都 (2020)', '葬送的芙莉莲 (2023)', '间谍过家家 (2022)'])
    '$root/动漫/$s',
  '$root/纪录片/地球脉动 (2006)',
  '$root/纪录片/宇宙时空之旅 (2014)',
};

Map<String, int> _build() {
  final files = <String, int>{};
  void add(String path, int size) => files[path] = size;

  for (final (name, year) in [
    ('盗梦空间', 2010),
    ('星际穿越', 2014),
    ('沙丘', 2021),
    ('沙丘2', 2024),
    ('奥本海默', 2023),
    ('银翼杀手2049', 2017),
    ('疯狂的麦克斯：狂暴之路', 2015),
    ('寄生虫', 2019),
    ('千与千寻', 2001),
    ('霸王别姬', 1993),
    ('花样年华', 2000),
    ('让子弹飞', 2010),
    ('流浪地球2', 2023),
    ('教父', 1972),
    ('肖申克的救赎', 1994),
    ('瞬息全宇宙', 2022),
    ('爱乐之城', 2016),
    ('海上钢琴师', 1998),
  ]) {
    final dir = '$root/电影/$name ($year)';
    add('$dir/$name ($year) - 2160p.mkv', _size(8, 62));
    add('$dir/$name ($year).zh.ass', 60000);
    add('$dir/poster.jpg', 400000);
  }

  void show(String base, String name, int seasons, int eps, double gb) {
    for (var s = 1; s <= seasons; s++) {
      for (var e = 1; e <= eps; e++) {
        final se = 'S${'$s'.padLeft(2, '0')}E${'$e'.padLeft(2, '0')}';
        add('$base/$name/Season $s/$name - $se.mkv', _size(gb * 0.7, gb * 1.3));
        add('$base/$name/Season $s/$name - $se.zh.ass', 45000);
      }
    }
  }

  show('$root/剧集', '老友记 (1994)', 10, 24, 0.7);
  show('$root/剧集', '绝命毒师 (2008)', 5, 13, 2.4);
  show('$root/剧集', '漫长的季节 (2023)', 1, 12, 3.1);
  show('$root/剧集', '繁花 (2023)', 1, 30, 1.8);
  show('$root/剧集', '三体 (2023)', 1, 30, 1.6);
  show('$root/动漫', '异兽魔都 (2020)', 2, 12, 1.1);
  show('$root/动漫', '葬送的芙莉莲 (2023)', 1, 28, 1.3);
  show('$root/动漫', '间谍过家家 (2022)', 2, 12, 1.0);
  show('$root/动漫', '海贼王 (1999)', 1, 60, 0.45);
  show('$root/动漫', '咒术回战 (2020)', 2, 24, 1.2);
  show('$root/纪录片', '地球脉动 (2006)', 1, 11, 4.2);
  show('$root/纪录片', '宇宙时空之旅 (2014)', 1, 13, 3.0);
  show('$root/纪录片', '风味人间 (2018)', 1, 8, 2.2);

  // Raw downloads nobody has organized yet.
  for (final n in [
    '[Nekomoe] Dandadan - 01-12 [1080p]',
    'The.Bear.S03.2160p.WEB-DL',
    'Shogun.2024.S01.1080p.BluRay',
    'Severance.S02.2160p.ATVP',
  ]) {
    for (var e = 1; e <= 10; e++) {
      add('$root/下载/$n/$n.E${'$e'.padLeft(2, '0')}.mkv', _size(1.5, 6));
    }
  }
  for (final n in [
    'Dune.Part.Two.2024.2160p.UHD.BluRay.REMUX.mkv',
    'Furiosa.2024.2160p.WEB-DL.mkv',
    'Civil.War.2024.1080p.BluRay.mkv',
  ]) {
    add('$root/下载/$n', _size(18, 70));
  }
  add('$root/下载/更多资源请访问 www.example.com.txt', 120);
  for (var i = 1; i <= 14; i++) {
    add('$root/待分类/VID_2023_$i.mp4', _size(0.6, 3.5));
  }

  for (var i = 1; i <= 120; i++) {
    add('$root/字幕包/sub_$i.ass', 70000 + i * 900);
  }
  for (var i = 1; i <= 40; i++) {
    add('$root/原声音乐/track_$i.flac', 38 * _mb + i * _mb);
  }
  return files;
}
