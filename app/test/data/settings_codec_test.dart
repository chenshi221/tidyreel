import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/bootstrap.dart';
import 'package:tidyreel/data/settings_codec.dart';
import 'package:tidyreel_core/tidyreel_core.dart';

void main() {
  test('naming profile and connection survive a JSON round trip', () {
    final profile = NamingProfile.vidhub.copyWith(
      tv: const NamingOptions(
        episodeStyle: EpisodeStyle.cross,
        separator: ' ',
        order: [NameField.episode, NameField.title],
        customTemplate: '{title} {season}x{episode}',
      ),
      tvDir: 'TV',
    );
    final back = namingProfileFromJson(namingProfileToJson(profile));
    expect(back.tv.episodeStyle, EpisodeStyle.cross);
    expect(back.tv.separator, ' ');
    expect(back.tv.order, [NameField.episode, NameField.title]);
    expect(back.tv.customTemplate, '{title} {season}x{episode}');
    expect(back.tvDir, 'TV');

    const c = ConnectionConfig(
      id: ConnectionId('x'),
      name: '家里 NAS',
      type: ConnectionType.alist,
      endpoint: 'http://nas:5244',
      favorites: ['/下载'],
      startDir: '/PC',
    );
    final c2 = connectionFromJson(connectionToJson(c));
    expect((c2.name, c2.type), ('家里 NAS', ConnectionType.alist));
    expect(c2.favorites, ['/下载']);
    expect(c2.startDir, '/PC');
    // Configs saved before startDir existed open at the root.
    final old = connectionToJson(c)..remove('startDir');
    expect(connectionFromJson(old).startDir, '/');
  });

  test('unknown enum names fall back to defaults', () {
    final o = namingOptionsFromJson({
      'episodeStyle': 'gone',
      'order': ['nope'],
    });
    expect(o.episodeStyle, const NamingOptions().episodeStyle);
    expect(o.order, const NamingOptions().order);
  });

  test('JsonStore persists to disk and survives a corrupt file', () {
    final dir = Directory.systemTemp.createTempSync('tidyreel');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/prefs.json');

    JsonStore.load(file).write('k', {'a': 1});
    expect(JsonStore.load(file).read('k'), {'a': 1});

    file.writeAsStringSync('{not json');
    expect(JsonStore.load(file).read('k'), isNull);
    expect(File('${file.path}.broken').existsSync(), isTrue);
  });
}
