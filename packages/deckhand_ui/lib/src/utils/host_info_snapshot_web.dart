import 'package:web/web.dart' as web;

String deckhandHostOperatingSystem() {
  final userAgent = web.window.navigator.userAgent.toLowerCase();
  if (userAgent.contains('windows')) return 'web windows';
  if (userAgent.contains('mac os') || userAgent.contains('macintosh')) {
    return 'web macos';
  }
  if (userAgent.contains('android')) return 'web android';
  if (userAgent.contains('iphone') || userAgent.contains('ipad')) {
    return 'web ios';
  }
  if (userAgent.contains('linux')) return 'web linux';
  return 'web';
}

String deckhandHostArchitecture() => 'browser';

String deckhandHostDartVersion() => 'web';
