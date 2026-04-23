import '../services/ssh_service.dart';
import '../models/printer_profile.dart';

/// What the probe found for a single stack/screen install candidate.
/// `installed=true` iff the install path exists AND (when checkable)
/// its declared systemd unit is present. `active` reflects whether
/// the service is currently running, when there's one to check.
class InstallState {
  const InstallState({
    required this.installed,
    required this.active,
    this.path,
  });
  final bool installed;
  final bool active;
  final String? path;
}

/// Snapshot of what actually exists / runs on a specific printer,
/// captured in a single SSH round-trip. Used by wizard screens to
/// grey-out options that are already-clean (service not installed,
/// file already deleted, etc.) so the user's decisions reflect the
/// machine's state, not just the profile's abstract list.
///
/// Each inner map is keyed by the profile's declared `id`. A missing
/// id means we didn't probe for it (older profile, probe timeout); an
/// entry with `false` means we probed and it's absent/inactive.
class PrinterState {
  const PrinterState({
    required this.services,
    required this.files,
    required this.paths,
    required this.stackInstalls,
    required this.screenInstalls,
    required this.python311Installed,
    this.osId,
    this.osCodename,
    this.osVersionId,
    this.pythonDefaultVersion,
    this.kernelRelease,
    this.probedAt,
  });

  final Map<String, ServiceRuntimeState> services;
  // File id -> "does at least one of its declared paths exist".
  final Map<String, bool> files;
  // Path id -> "does the path exist".
  final Map<String, bool> paths;
  // Stack-component id (moonraker, kiauh, crowsnest, fluidd, mainsail,
  // ...) -> InstallState. Lets the wizard tell "already installed" from
  // "user should pick".
  final Map<String, InstallState> stackInstalls;
  // Screen id -> InstallState. Same idea for profile.screens.
  final Map<String, InstallState> screenInstalls;
  final bool python311Installed;
  // From /etc/os-release. The profile often claims the printer is
  // still on the vendor-shipped OS, but users upgrade - we should key
  // conditional steps off what's actually there.
  final String? osId;             // "debian", "ubuntu", "armbian"
  final String? osCodename;       // "buster", "bookworm", "trixie"
  final String? osVersionId;      // "10", "12", "13"
  final String? pythonDefaultVersion; // "3.7.3", "3.13.0"
  final String? kernelRelease;    // `uname -r`
  // Null iff a probe hasn't run yet.
  final DateTime? probedAt;

  static const PrinterState empty = PrinterState(
    services: {},
    files: {},
    paths: {},
    stackInstalls: {},
    screenInstalls: {},
    python311Installed: false,
  );
}

class ServiceRuntimeState {
  const ServiceRuntimeState({
    required this.unitExists,
    required this.unitActive,
    required this.processRunning,
    required this.launcherScriptExists,
  });

  final bool unitExists;
  final bool unitActive;
  final bool processRunning;
  // launched_by.kind=script targets a file on disk. True iff that file
  // still exists - tells the UI whether this service is truly present
  // or is already-stripped vendor bloat.
  final bool launcherScriptExists;

  /// A service counts as "present" if ANY of its detection surfaces
  /// match. If nothing matches, the declaration in the profile is
  /// abstract-only for this specific machine and the UI can dim the
  /// option.
  bool get present =>
      unitExists || unitActive || processRunning || launcherScriptExists;
}

/// Builds the single shell script that captures all the state we
/// care about in one `ssh.run`. Output is a JSON-ish line-per-result
/// protocol that the parser on the Dart side expects.
///
/// Why a custom protocol instead of multiple round-trips: SSH
/// session setup over a pty-less dartssh2 run costs ~50-200 ms per
/// call; multiplying that by ~20 service + file checks quickly adds
/// up. One round-trip + a trivial parser is an order of magnitude
/// cheaper.
class PrinterStateProbe {
  PrinterStateProbe({required this.ssh});
  final SshService ssh;

  Future<PrinterState> probe({
    required SshSession session,
    required PrinterProfile profile,
  }) async {
    final script = _buildScript(profile);
    final res = await ssh.run(
      session,
      script,
      timeout: const Duration(seconds: 30),
    );
    // Non-zero exit is treated as "probe didn't work"; callers still
    // get a [PrinterState] but every field is conservatively false,
    // so screens fall back to showing all options (same behaviour as
    // before probing existed).
    return _parseReport(res.stdout);
  }

  String _buildScript(PrinterProfile profile) {
    final inv = profile.stockOs;
    final lines = <String>[
      '#!/bin/sh',
      // We can't rely on bash being /bin/sh on every distro, so stay
      // POSIX. Disable exit-on-error: we WANT every probe to run,
      // even if an earlier one fails. Set -u unset-var strictness
      // also avoided because some probes reference maybe-empty vars.
      'set +e',
      'say() { printf "%s\\t%s\\n" "\$1" "\$2"; }',
      // --------------------------------------------------------
      // OS identity. Profile's `os.stock` block is just a hint; the
      // live machine might be on an upgraded / different distro.
      // Steps that assume the stock OS (sources.list rewrites,
      // archive.debian.org fallbacks, etc.) MUST gate on these.
      // /etc/os-release is standard on every systemd distro.
      '. /etc/os-release 2>/dev/null',
      'say os:id "\${ID:-unknown}"',
      'say os:codename "\${VERSION_CODENAME:-unknown}"',
      'say os:version_id "\${VERSION_ID:-unknown}"',
      'say kernel "\$(uname -r 2>/dev/null || echo unknown)"',
      // --------------------------------------------------------
      // Python: default `python3` version (drives profile
      // python_min checks) + explicit 3.11 presence (drives the
      // python_rebuild_if_needed short-circuit).
      'if command -v python3 >/dev/null 2>&1; then',
      r'  say python:default "$(python3 -c "import sys;print(\".\".join(map(str,sys.version_info[:3])))" 2>/dev/null || echo unknown)"',
      'else',
      '  say python:default unknown',
      'fi',
      'command -v python3.11 >/dev/null 2>&1 && say python311 present || say python311 absent',
    ];
    for (final svc in inv.services) {
      final unit = _shellEscape(svc.raw['systemd_unit'] as String? ?? '');
      final proc = _shellEscape(svc.raw['process_pattern'] as String? ?? '');
      final launchedBy = (svc.raw['launched_by'] as Map?)
          ?.cast<String, dynamic>();
      final scriptPath = launchedBy != null && launchedBy['kind'] == 'script'
          ? (launchedBy['path'] as String? ?? '')
          : '';
      final qScript = _shellEscape(scriptPath);
      // `id` is inlined unquoted on purpose. Profile ids are already
      // constrained to `[a-z0-9_-]+` so there's nothing to escape,
      // and inlining them keeps the probe's wire format (`svc:<id>:
      // <facet>`) matching cleanly with the parser expectations.
      final id = svc.id;
      lines.addAll([
        '# $id',
        if (unit != "''")
          '( systemctl list-unit-files $unit >/dev/null 2>&1 && '
              'say svc:$id:unit_exists 1 ) || say svc:$id:unit_exists 0',
        if (unit != "''")
          '( systemctl is-active $unit >/dev/null 2>&1 && '
              'say svc:$id:unit_active 1 ) || say svc:$id:unit_active 0',
        if (proc != "''")
          '( pgrep -f $proc >/dev/null 2>&1 && '
              'say svc:$id:proc_running 1 ) || say svc:$id:proc_running 0',
        if (qScript != "''")
          '[ -e $qScript ] && say svc:$id:launcher_exists 1 || '
              'say svc:$id:launcher_exists 0',
      ]);
    }
    for (final f in inv.files) {
      final id = f.id;
      final paths = f.paths.map(_shellEscape).toList();
      // A file id is "present" if ANY of its declared paths exist.
      // Glob patterns: use `ls -d` and check exit; find-based probing
      // would be heavier and needs the pattern escaped differently.
      if (paths.isEmpty) {
        lines.add('say file:$id 0');
      } else {
        final test = paths.map((p) => 'ls -d $p >/dev/null 2>&1').join(' || ');
        lines.add('( $test ) && say file:$id 1 || say file:$id 0');
      }
    }
    for (final pth in inv.paths) {
      final id = pth.id;
      final path = _shellEscape(pth.path);
      lines.add('[ -e $path ] && say path:$id 1 || say path:$id 0');
    }
    // --------------------------------------------------------
    // Stack components: moonraker / kiauh / crowsnest / webui
    // choices. For each, check the install_path is present AND,
    // when a systemd unit is declared, that it's active.
    final stack = profile.stack;
    _addStackProbe(lines, 'moonraker', stack.moonraker);
    _addStackProbe(lines, 'kiauh', stack.kiauh);
    _addStackProbe(lines, 'crowsnest', stack.crowsnest);
    final webuiChoices = ((stack.webui?['choices'] as List?) ?? const [])
        .cast<Map>();
    for (final raw in webuiChoices) {
      final c = raw.cast<String, dynamic>();
      final id = c['id'] as String?;
      if (id == null) continue;
      _addStackProbe(lines, id, c);
    }
    // --------------------------------------------------------
    // Screens: profile.screens[*].install_path. Many screens are
    // just bundled directories with no systemd unit - we only check
    // install_path existence in that case.
    for (final sc in profile.screens) {
      final raw = sc.raw;
      final installPath = raw['install_path'] as String?
          ?? raw['source_path'] as String?;
      if (installPath == null) continue;
      final qPath = _shellPathEscape(installPath);
      lines.add('[ -e $qPath ] && say screen:${sc.id}:installed 1 || say screen:${sc.id}:installed 0');
      final unit = raw['systemd_unit'] as String?;
      if (unit != null && unit.isNotEmpty) {
        final qUnit = _shellEscape(unit);
        lines.add(
          '( systemctl is-active $qUnit >/dev/null 2>&1 && '
          'say screen:${sc.id}:active 1 ) || say screen:${sc.id}:active 0',
        );
      }
      lines.add('say screen:${sc.id}:path $qPath');
    }
    return lines.join('\n');
  }

  void _addStackProbe(
    List<String> lines,
    String id,
    Map<String, dynamic>? cfg,
  ) {
    if (cfg == null) return;
    final installPath = cfg['install_path'] as String?;
    if (installPath == null) return;
    final qPath = _shellPathEscape(installPath);
    lines.add('[ -d $qPath ] && say stack:$id:installed 1 || say stack:$id:installed 0');
    lines.add('say stack:$id:path $qPath');
    final unit = cfg['systemd_unit'] as String?;
    if (unit != null && unit.isNotEmpty) {
      final qUnit = _shellEscape(unit);
      lines.add(
        '( systemctl is-active $qUnit >/dev/null 2>&1 && '
        'say stack:$id:active 1 ) || say stack:$id:active 0',
      );
    }
  }

  /// Escape a path that may start with `~` for use as a shell argument.
  /// Single-quoting a `~/foo` would suppress tilde expansion (bash
  /// only expands `~` when unquoted or at the very start), so we
  /// swap to `"$HOME/foo"` when we see one. Absolute paths keep the
  /// simple single-quote form.
  String _shellPathEscape(String path) {
    if (path == '~') return r'"$HOME"';
    if (path.startsWith('~/')) {
      final rest = path.substring(2).replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      return '"\$HOME/$rest"';
    }
    return _shellEscape(path);
  }

  PrinterState _parseReport(String stdout) {
    final services = <String, _ServiceAcc>{};
    final files = <String, bool>{};
    final paths = <String, bool>{};
    final stackAcc = <String, _InstallAcc>{};
    final screenAcc = <String, _InstallAcc>{};
    var python = false;
    String? osId;
    String? osCodename;
    String? osVersionId;
    String? pythonDefault;
    String? kernel;

    for (final rawLine in stdout.split('\n')) {
      final line = rawLine.trimRight();
      if (line.isEmpty) continue;
      final parts = line.split('\t');
      if (parts.length != 2) continue;
      final key = parts[0];
      final val = parts[1];
      // Strip the leading/trailing double-quotes that /etc/os-release
      // fields arrive with. "debian" vs debian is the same to us.
      final unq = val.startsWith('"') && val.endsWith('"') && val.length >= 2
          ? val.substring(1, val.length - 1)
          : val;
      if (key == 'os:id') { osId = unq; continue; }
      if (key == 'os:codename') { osCodename = unq; continue; }
      if (key == 'os:version_id') { osVersionId = unq; continue; }
      if (key == 'kernel') { kernel = unq; continue; }
      if (key == 'python:default') { pythonDefault = unq; continue; }
      if (key == 'python311') {
        python = val == 'present';
        continue;
      }
      if (key.startsWith('svc:')) {
        final rest = key.substring(4);
        final idx = rest.lastIndexOf(':');
        if (idx < 0) continue;
        final id = rest.substring(0, idx);
        final facet = rest.substring(idx + 1);
        final acc = services.putIfAbsent(id, _ServiceAcc.new);
        final on = val == '1';
        switch (facet) {
          case 'unit_exists':
            acc.unitExists = on;
          case 'unit_active':
            acc.unitActive = on;
          case 'proc_running':
            acc.procRunning = on;
          case 'launcher_exists':
            acc.launcherExists = on;
        }
        continue;
      }
      if (key.startsWith('file:')) {
        files[key.substring(5)] = val == '1';
        continue;
      }
      if (key.startsWith('path:')) {
        paths[key.substring(5)] = val == '1';
        continue;
      }
      if (key.startsWith('stack:')) {
        _accumulateInstall(stackAcc, key.substring(6), val);
        continue;
      }
      if (key.startsWith('screen:')) {
        _accumulateInstall(screenAcc, key.substring(7), val);
        continue;
      }
    }

    final svcState = {
      for (final e in services.entries)
        e.key: ServiceRuntimeState(
          unitExists: e.value.unitExists,
          unitActive: e.value.unitActive,
          processRunning: e.value.procRunning,
          launcherScriptExists: e.value.launcherExists,
        ),
    };

    return PrinterState(
      services: svcState,
      files: files,
      paths: paths,
      stackInstalls: {
        for (final e in stackAcc.entries)
          e.key: InstallState(
            installed: e.value.installed,
            active: e.value.active,
            path: e.value.path,
          ),
      },
      screenInstalls: {
        for (final e in screenAcc.entries)
          e.key: InstallState(
            installed: e.value.installed,
            active: e.value.active,
            path: e.value.path,
          ),
      },
      python311Installed: python,
      osId: osId,
      osCodename: osCodename,
      osVersionId: osVersionId,
      pythonDefaultVersion: pythonDefault,
      kernelRelease: kernel,
      probedAt: DateTime.now(),
    );
  }

  /// Fold a single `stack:<id>:<facet>` or `screen:<id>:<facet>` probe
  /// line into its per-id accumulator. Unknown facets are ignored so
  /// the parser is forward-compatible with future probe additions.
  void _accumulateInstall(
    Map<String, _InstallAcc> accMap,
    String rest,
    String val,
  ) {
    final idx = rest.lastIndexOf(':');
    if (idx < 0) return;
    final id = rest.substring(0, idx);
    final facet = rest.substring(idx + 1);
    final acc = accMap.putIfAbsent(id, _InstallAcc.new);
    switch (facet) {
      case 'installed':
        acc.installed = val == '1';
      case 'active':
        acc.active = val == '1';
      case 'path':
        acc.path = val;
    }
  }

  String _shellEscape(String s) {
    if (s.isEmpty) return "''";
    return "'${s.replaceAll("'", r"'\''")}'";
  }
}

class _ServiceAcc {
  bool unitExists = false;
  bool unitActive = false;
  bool procRunning = false;
  bool launcherExists = false;
}

class _InstallAcc {
  bool installed = false;
  bool active = false;
  String? path;
}
