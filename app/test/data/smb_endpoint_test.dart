import 'package:flutter_test/flutter_test.dart';
import 'package:tidyreel/data/smb_backend.dart';

void main() {
  test('parseSmbEndpoint: URL, UNC, encoded, sub-folder', () {
    expect(parseSmbEndpoint('smb://nas:4445/影视'), (
      host: 'nas:4445',
      share: '影视',
      base: '',
    ));
    expect(parseSmbEndpoint(r'\\nas\影视\下载'), (
      host: 'nas',
      share: '影视',
      base: '下载',
    ));
    expect(parseSmbEndpoint('smb://nas/%E5%BD%B1%E8%A7%86'), (
      host: 'nas',
      share: '影视',
      base: '',
    ));
    expect(parseSmbEndpoint('smb://nas'), isNull);
  });
}
