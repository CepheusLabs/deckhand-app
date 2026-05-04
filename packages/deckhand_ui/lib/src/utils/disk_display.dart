import 'package:deckhand_core/deckhand_core.dart';

final RegExp _physicalDrivePrefixRe = RegExp(
  r'^\\\\\.\\',
  caseSensitive: false,
);
final RegExp _physicalDriveIdRe = RegExp(
  r'^physicaldrive([0-9]+)$',
  caseSensitive: false,
);

String diskDisplayName(DiskInfo disk) {
  final model = disk.model.trim();
  if (_isFriendlyModel(model, disk)) return model;
  return _fallbackDiskName(disk);
}

String diskDisplaySummary(DiskInfo disk) {
  return '${diskDisplayName(disk)} · ${diskBusLabel(disk)} · '
      '${formatDiskSizeGiB(disk.sizeBytes, fractionDigits: 2)}';
}

String diskTechnicalLabel(DiskInfo disk) {
  final id = disk.id.trim();
  final driveNumber = _physicalDriveNumber(id);
  if (driveNumber != null) return 'Windows disk $driveNumber';
  if (id.isNotEmpty) return id;
  return disk.path.trim();
}

String diskBusLabel(DiskInfo disk) {
  final bus = disk.bus.trim();
  if (bus.isEmpty) return 'Unknown bus';
  return bus;
}

String formatDiskSizeGiB(int bytes, {required int fractionDigits}) {
  return '${(bytes / (1 << 30)).toStringAsFixed(fractionDigits)} GiB';
}

bool _isFriendlyModel(String model, DiskInfo disk) {
  if (model.isEmpty) return false;
  final lower = model.toLowerCase();
  if (lower == 'unknown' || lower == 'unknown disk') return false;
  if (_sameTechnicalValue(model, disk.id) ||
      _sameTechnicalValue(model, disk.path)) {
    return false;
  }
  return _physicalDriveNumber(model) == null;
}

bool _sameTechnicalValue(String left, String right) {
  if (right.trim().isEmpty) return false;
  return left.trim().toLowerCase() == right.trim().toLowerCase();
}

String _fallbackDiskName(DiskInfo disk) {
  final bus = disk.bus.trim().toUpperCase();
  if (disk.removable || bus == 'USB' || bus == 'SD' || bus == 'MMC') {
    return 'Generic STORAGE DEVICE';
  }
  if (bus.isNotEmpty && bus != 'UNKNOWN') return '$bus storage device';
  return 'Storage device';
}

String? _physicalDriveNumber(String value) {
  final compact = value
      .trim()
      .replaceFirst(_physicalDrivePrefixRe, '')
      .replaceAll(RegExp(r'[\s_-]+'), '')
      .toLowerCase();
  final match = _physicalDriveIdRe.firstMatch(compact);
  return match?.group(1);
}
