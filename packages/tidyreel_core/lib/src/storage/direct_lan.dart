import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

final _bracketsRe = RegExp(r'^\[|\]$');
final _privateSuffixRe = RegExp(
  r'\.(?:local|lan|home|home\.arpa|internal|ts\.net)$',
);

bool _isPrivateIPv4(int b0, int b1) =>
    b0 == 10 ||
    b0 == 127 ||
    (b0 == 172 && b1 >= 16 && b1 < 32) ||
    (b0 == 192 && b1 == 168) ||
    (b0 == 169 && b1 == 254) ||
    (b0 == 100 && b1 >= 64 && b1 < 128);

bool _isIPv4MappedIPv6(List<int> b) {
  if (b.length != 16) return false;
  for (var i = 0; i < 10; i++) {
    if (b[i] != 0) return false;
  }
  return b[10] == 0xff && b[11] == 0xff;
}

/// Whether [host] is on this network or a private overlay: loopback, RFC 1918,
/// link-local, CGNAT / Tailscale (100.64.0.0/10), IPv6 ULA / link-local /
/// IPv4-mapped private IPv6, or a bare / .local / .lan / .home / .home.arpa /
/// .internal / .ts.net name (with optional trailing dot). A system proxy
/// (Clash, Surge) can't reach these and answers 502, so NAS connections skip it.
bool isPrivateHost(String host) {
  var h = host.trim().toLowerCase().replaceAll(_bracketsRe, '');
  while (h.endsWith('.')) {
    h = h.substring(0, h.length - 1);
  }
  if (h.isEmpty) return false;
  if (!h.contains('.') && !h.contains(':')) return true; // "nas"
  if (_privateSuffixRe.hasMatch(h)) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return false;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return _isPrivateIPv4(b[0], b[1]);
  }
  if (_isIPv4MappedIPv6(b)) {
    return _isPrivateIPv4(b[12], b[13]);
  }
  return ip.isLoopback || ip.isLinkLocal || (b[0] & 0xfe) == 0xfc;
}

/// Makes [dio] connect directly to [isPrivateHost] hosts and use the
/// environment's proxy (HTTP_PROXY / NO_PROXY) for everything else.
Dio directForPrivateHosts(Dio dio) =>
    dio
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => HttpClient()
          ..findProxy = (uri) => isPrivateHost(uri.host)
              ? 'DIRECT'
              : HttpClient.findProxyFromEnvironment(uri),
      );
