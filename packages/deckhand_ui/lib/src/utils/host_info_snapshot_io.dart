import 'dart:ffi' as ffi;
import 'dart:io';

String deckhandHostOperatingSystem() {
  return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
}

String deckhandHostArchitecture() {
  return ffi.Abi.current().toString();
}

String deckhandHostDartVersion() {
  return Platform.version.split(' ').first;
}
