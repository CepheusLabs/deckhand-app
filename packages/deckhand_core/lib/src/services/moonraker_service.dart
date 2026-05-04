/// Moonraker WebSocket / HTTP client.
abstract class MoonrakerService {
  Future<KlippyInfo> info({required String host, int port = 7125});

  /// Query `print_stats` to decide whether a destructive op is safe.
  Future<bool> isPrinting({required String host, int port = 7125});

  /// Query live Klipper object status through Moonraker.
  ///
  /// Returns the `result.status` map keyed by object name. Callers can
  /// request objects such as `extruder`, `heater_bed`, `toolhead`,
  /// `print_stats`, and `configfile`.
  Future<Map<String, dynamic>> queryObjects({
    required String host,
    int port = 7125,
    required List<String> objects,
  });

  /// Run a G-code script through Moonraker.
  ///
  /// Used for guided tuning actions like `PID_CALIBRATE`,
  /// `SHAPER_CALIBRATE`, and temporary pressure-advance changes.
  Future<void> runGCode({
    required String host,
    int port = 7125,
    required String script,
  });

  /// Enumerate all Klipper objects currently registered on the printer.
  /// Returns names like `gcode_macro`, `phrozen_dev:arco`, `stepper_x`.
  /// Used for printer-identity fingerprinting during discovery.
  Future<List<String>> listObjects({required String host, int port = 7125});

  /// Fetch a plain-text file under Moonraker's `config` root, e.g.
  /// `~/printer_data/config/<filename>`. Returns the raw bytes as a
  /// string on success, or null when the file is absent / unreadable /
  /// Moonraker refuses the request. Used to read Deckhand's marker
  /// file during printer discovery.
  Future<String?> fetchConfigFile({
    required String host,
    int port = 7125,
    required String filename,
  });
}

class KlippyInfo {
  const KlippyInfo({
    required this.state,
    required this.hostname,
    required this.softwareVersion,
    required this.klippyState,
  });
  final String state;
  final String hostname;
  final String softwareVersion;
  final String klippyState;
}
