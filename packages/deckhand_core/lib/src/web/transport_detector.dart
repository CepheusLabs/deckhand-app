import 'transport_capabilities.dart';
import 'transport_detector_stub.dart'
    if (dart.library.html) 'transport_detector_web.dart'
    as impl;

DeckhandTransportAvailability detectDeckhandWebTransports() =>
    impl.detectDeckhandWebTransports();
