import 'dart:io';

Future<List<String>> localIpv4Cidrs() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.IPv4,
    );
    final cidrs = <String>{};
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        final parts = addr.address.split('.');
        if (parts.length != 4) continue;
        cidrs.add('${parts[0]}.${parts[1]}.${parts[2]}.0/24');
      }
    }
    return cidrs.toList();
  } catch (_) {
    return const [];
  }
}
