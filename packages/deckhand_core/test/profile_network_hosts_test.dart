import 'package:deckhand_core/deckhand_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('profileNetworkHosts', () {
    test('combines declared hosts and download/source hosts', () {
      final profile = PrinterProfile.fromJson({
        'profile_id': 'test-printer',
        'required_hosts': [
          'GitHub.COM',
          ' https://api.github.com/repos/x/y ',
          'bad host',
        ],
        'os': {
          'fresh_install_options': [
            {
              'id': 'img',
              'display_name': 'Image',
              'url': 'https://downloads.example.com/images/test.img.xz',
            },
          ],
        },
        'firmware': {
          'choices': [
            {
              'id': 'kalico',
              'display_name': 'Kalico',
              'repo': 'https://github.com/KalicoCrew/kalico',
              'ref': 'main',
            },
          ],
        },
        'stack': {
          'moonraker': {'repo': 'https://github.com/Arksine/moonraker'},
          'webui': {
            'choices': [
              {
                'id': 'mainsail',
                'release_repo': 'mainsail-crew/mainsail',
                'asset_pattern': 'mainsail.zip',
              },
            ],
          },
        },
      });

      expect(profileNetworkHosts(profile), [
        'api.github.com',
        'downloads.example.com',
        'github-releases.githubusercontent.com',
        'github.com',
        'objects.githubusercontent.com',
        'release-assets.githubusercontent.com',
      ]);
    });

    test('normalizes host candidates without accepting path syntax', () {
      expect(normalizeHostCandidate(' Example.COM '), 'example.com');
      expect(
        normalizeHostCandidate('https://Example.COM:8443/path'),
        'example.com',
      );
      expect(normalizeHostCandidate('example.com/path'), isNull);
      expect(normalizeHostCandidate('not a host'), isNull);
    });

    test('includes GitHub release asset hosts for OS image URLs', () {
      final profile = PrinterProfile.fromJson({
        'profile_id': 'test-printer',
        'os': {
          'fresh_install_options': [
            {
              'id': 'img',
              'display_name': 'Image',
              'url':
                  'https://github.com/armbian/community/releases/download/'
                  '26.2.0-trunk.821/image.img.xz',
            },
          ],
        },
      });

      expect(profileNetworkHosts(profile), [
        'api.github.com',
        'github-releases.githubusercontent.com',
        'github.com',
        'objects.githubusercontent.com',
        'release-assets.githubusercontent.com',
      ]);
    });

    test('ignores malformed webui choice maps without dropping good hosts', () {
      final profile = PrinterProfile.fromJson({
        'profile_id': 'test-printer',
        'stack': {
          'webui': {
            'choices': [
              {1: 'bad key', 'repo': 'https://example.com/webui.git'},
              'not a map',
            ],
          },
        },
      });

      expect(profileNetworkHosts(profile), ['example.com']);
    });

    test('ignores malformed stack URLs and webui choices shape', () {
      final profile = PrinterProfile.fromJson({
        'profile_id': 'test-printer',
        'stack': {
          'moonraker': {'repo': 42, 'url': false},
          'kiauh': {'repo': 'https://github.com/dw-0/kiauh'},
          'webui': {
            'choices': {'not': 'a list'},
          },
        },
      });

      expect(profileNetworkHosts(profile), ['github.com']);
    });
  });
}
