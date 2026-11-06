import 'package:flutter/services.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/utils/ext.dart';

String? _cachedProxy;

DateTime? _cachedProxyTime;

Future<String?> getProxy() async {
  if (_cachedProxyTime != null &&
      DateTime.now().difference(_cachedProxyTime!).inSeconds < 1) {
    return _cachedProxy;
  }
  String? proxy = await _getProxy();
  _cachedProxy = proxy;
  _cachedProxyTime = DateTime.now();
  return proxy;
}

String? _normalizeProxy(String proxy) {
  var candidate = proxy.trim();
  if (candidate.isEmpty) {
    return null;
  }
  // Some platforms return values like "PROXY host:port".
  candidate = candidate.replaceFirst(
    RegExp(r'^(PROXY|HTTP|HTTPS|SOCKS5?)\s+', caseSensitive: false),
    '',
  );
  // Strip an explicit scheme, if any.
  candidate = candidate.replaceFirst(
    RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*://'),
    '',
  );
  // Drop a trailing path, which can appear in PAC results.
  if (candidate.contains('/')) {
    candidate = candidate.split('/').first;
  }
  candidate = candidate.removeAllBlank;

  // Accept hostnames, IPv4/IPv6 literals and optional credentials.
  final regex = RegExp(
    r'^(?:[^@\s]+@)?(\[[0-9a-fA-F:]+\]|[^\s:@]+):\d{1,5}$',
  );
  if (!regex.hasMatch(candidate)) {
    return null;
  }
  return candidate;
}

Future<String?> _getProxy() async {
  if ((appdata.settings['proxy'] as String).removeAllBlank == "direct") {
    return null;
  }
  if (appdata.settings['proxy'] != "system") return appdata.settings['proxy'];

  String res;
  if (!App.isLinux) {
    const channel = MethodChannel("venera/method_channel");
    try {
      res = await channel.invokeMethod("getProxy");
    } catch (e) {
      return null;
    }
  } else {
    res = "No Proxy";
  }
  if (res == "No Proxy") return null;

  if (res.contains(";")) {
    String? httpProxy;
    var proxies = res.split(";");
    for (String proxy in proxies) {
      proxy = proxy.removeAllBlank;
      if (proxy.startsWith('https=')) {
        var normalized = _normalizeProxy(proxy.substring(6));
        if (normalized != null) {
          return normalized;
        }
      } else if (proxy.startsWith('http=')) {
        httpProxy ??= _normalizeProxy(proxy.substring(5));
      }
    }
    if (httpProxy != null) {
      return httpProxy;
    }
  }

  return _normalizeProxy(res);
}
