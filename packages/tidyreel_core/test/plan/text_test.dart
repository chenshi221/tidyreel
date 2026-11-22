import 'package:test/test.dart';
import 'package:tidyreel_core/src/plan/text.dart';

void main() {
  group('tradToSimp table invariants', () {
    test('contains a comprehensive BMP 1-to-1 map with no chains', () {
      expect(tradToSimp.length, greaterThanOrEqualTo(2500));
      for (final entry in tradToSimp.entries) {
        final kRunes = entry.key.runes.toList();
        final vRunes = entry.value.runes.toList();
        expect(kRunes.length, 1, reason: 'key ${entry.key} must be 1 rune');
        expect(vRunes.length, 1, reason: 'val ${entry.value} must be 1 rune');
        expect(entry.key, isNot(entry.value));
        expect(
          kRunes.single,
          inInclusiveRange(0x3400, 0x9FFF),
          reason: 'key ${entry.key} must be BMP CJK',
        );
        expect(
          vRunes.single,
          inInclusiveRange(0x3400, 0x9FFF),
          reason: 'val ${entry.value} must be BMP CJK',
        );
        expect(
          tradToSimp.containsKey(entry.value),
          isFalse,
          reason:
              'chain detected: ${entry.key} -> ${entry.value} -> ${tradToSimp[entry.value]}',
        );
      }
    });

    test('covers key Traditional -> Simplified character pairs accurately', () {
      const pairs = <String, String>{
        '獵': '猎',
        '滅': '灭',
        '進': '进',
        '擊': '击',
        '偵': '侦',
        '銀': '银',
        '戰': '战',
        '劍': '剑',
        '龍': '龙',
        '國': '国',
        '學': '学',
        '書': '书',
        '語': '语',
        '點': '点',
        '愛': '爱',
        '變': '变',
        '邊': '边',
        '關': '关',
        '開': '开',
        '門': '门',
        '問': '问',
        '間': '间',
        '聞': '闻',
        '電': '电',
        '車': '车',
        '馬': '马',
        '鳥': '鸟',
        '魚': '鱼',
        '風': '风',
        '飛': '飞',
        '飯': '饭',
        '飲': '饮',
        '體': '体',
        '頭': '头',
        '題': '题',
        '顏': '颜',
        '類': '类',
        '麗': '丽',
        '齊': '齐',
        '齒': '齿',
        '龜': '龟',
        '妳': '你',
        '牠': '它',
        '裏': '里',
        '裡': '里',
        '臺': '台',
        '檯': '台',
        '颱': '台',
      };
      pairs.forEach((trad, simp) {
        expect(tradToSimp[trad], simp, reason: '$trad -> $simp');
      });
    });

    test(
      'does not corrupt Simplified Chinese titles or sensitive characters',
      () {
        const simplifiedTitles = [
          '哪吒之魔童降世',
          '搏击俱乐部',
          '摔跤吧！爸爸',
          '大阪物语',
          '世界名著',
          '乾隆王朝',
          '姊妹情深',
          '繁花',
          '狂飙',
          '庆余年',
          '三体',
          '流浪地球',
          '甄嬛传',
          '琅琊榜',
          '让子弹飞',
          '肖申克的救赎',
          '盗梦空间',
          '权力的游戏',
          '绝命毒师',
          '进击的巨人',
          '鬼灭之刃',
          '海贼王',
          '葬送的芙莉莲',
          '间谍过家家',
          '药师少女的独语',
        ];
        for (final title in simplifiedTitles) {
          expect(toSimplified(title), title, reason: title);
        }
      },
    );
  });

  group('HK/TW movie, TV, and anime title normalization', () {
    test(
      'toSimplified and normTitle match Traditional and Simplified pairs',
      () {
        const pairs = <String, String>{
          '鬼滅之刃': '鬼灭之刃',
          '進擊的巨人': '进击的巨人',
          '名偵探柯南': '名侦探柯南',
          '全職獵人': '全职猎人',
          '銀魂': '银魂',
          '權力的遊戲': '权力的游戏',
          '絕命毒師': '绝命毒师',
          '讓子彈飛': '让子弹飞',
          '盜夢空間': '盗梦空间',
          '星際穿越': '星际穿越',
          '無間道': '无间道',
          '重慶森林': '重庆森林',
          '霸王別姬': '霸王别姬',
          '花樣年華': '花样年华',
          '臥虎藏龍': '卧虎藏龙',
          '千與千尋': '千与千寻',
          '龍貓': '龙猫',
          '葬送的芙莉蓮': '葬送的芙莉莲',
          '間諜過家家': '间谍过家家',
          '慶餘年': '庆余年',
          '甄嬛傳': '甄嬛传',
          '長安十二時辰': '长安十二时辰',
          '狂飆': '狂飙',
          '我們與惡的距離': '我们与恶的距离',
          '想見妳': '想见你',
          '華燈初上': '华灯初上',
          '俗女養成記': '俗女养成记',
          '海賊王': '海贼王',
          '咒術迴戰': '咒术回战',
          '鏈鋸人': '链锯人',
          '灌籃高手': '灌篮高手',
          '鋼之鍊金術師': '钢之炼金术师',
          '命運石之門': '命运石之门',
          '新世紀福音戰士': '新世纪福音战士',
          '機動戰士鋼彈': '机动战士钢弹',
          '聖鬥士星矢': '圣斗士星矢',
          '科學超電磁砲': '科学超电磁炮',
          '輝夜姬想讓人告白': '辉夜姬想让人告白',
          '孤獨搖滾': '孤独摇滚',
          '藥師少女的獨語': '药师少女的独语',
          '東邪西毒': '东邪西毒',
          '大話西遊': '大话西游',
          '頭文字D': '头文字D',
          '賭神': '赌神',
        };
        pairs.forEach((trad, simp) {
          expect(toSimplified(trad), simp, reason: trad);
          expect(normTitle(trad), normTitle(simp), reason: trad);
          expect(similarity(trad, simp), 1.0, reason: trad);
        });
      },
    );

    test('toSimplified preserves Latin case, digits, and punctuation', () {
      expect(
        toSimplified('《進擊的巨人》 Season 4 - Part 2!'),
        '《进击的巨人》 Season 4 - Part 2!',
      );
    });
  });

  group('existing text utilities backwards compatibility', () {
    test(
      'path, Han detection, and relaxedQueries helpers behave consistently',
      () {
        expect(dirOf('/movies/Inception/a.mkv'), '/movies/Inception');
        expect(dirOf('/a.mkv'), '/');
        expect(baseOf('/movies/Inception/a.mkv'), 'a.mkv');
        expect(stem('Inception.2010.mkv'), 'Inception.2010');
        expect(extOf('Inception.2010.mkv'), 'mkv');
        expect(hasHan('盜夢空間'), isTrue);
        expect(hasHan('Inception'), isFalse);
        expect(
          relaxedQueries('R人生复本', 'R人生复本 Dark Matter (2024)'),
          containsAll(['人生复本', 'Dark Matter']),
        );
      },
    );
  });
}
