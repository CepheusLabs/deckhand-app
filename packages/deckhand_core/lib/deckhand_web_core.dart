/// Browser-safe Deckhand core surface.
///
/// The full `deckhand_core.dart` library includes native wizard execution
/// services for SSH, filesystem, and block devices. Browser builds import this
/// narrower surface for transport gating and browser flashing without pulling
/// `dart:io` into the web compiler.
library;

export 'src/web/transport_capabilities.dart';
export 'src/web/transport_detector.dart';
export 'src/web/flash_transports.dart';
export 'src/web/browser_flash_delegates.dart';
export 'src/models/printer_profile.dart'
    show
        FlowSpec,
        PrinterProfile,
        ProfileFormatException,
        ProfileStatus,
        ProfileStatusX;
export 'src/web/web_profile.dart';
