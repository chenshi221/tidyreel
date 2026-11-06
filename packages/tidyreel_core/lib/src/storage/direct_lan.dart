import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Whether [host] is on this network or a private overlay: loopback, RFC 1918,
/// link-local, CGNAT / Tailscale (100.64.0.0/10), IPv6 ULA / link-local, or a
/// bare / .local / .lan / .ts.net name. A system proxy (Clash, Surge) can't
/// reach these and answers 502, so NAS connections skip it.
bool isPrivateHost(String host) {
  final h = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  if (!h.contains('.') && !h.contains(':')) return true; // "nas"
  if (RegExp(r'\.(local|lan|home|internal|ts\.net)$').hasMatch(h)) return true;
  final ip = InternetAddress.tryParse(h);
  if (ip == null) return false;
  final b = ip.rawAddress;
  if (ip.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        b[0] == 127 ||
        (b[0] == 172 && b[1] >= 16 && b[1] < 32) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 100 && b[1] >= 64 && b[1] < 128);
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
