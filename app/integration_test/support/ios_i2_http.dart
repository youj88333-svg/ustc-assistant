import 'dart:io';

/// Zone-local fence for synthetic I2 checks. Calling the superclass creates the
/// underlying client directly; calling HttpClient here would recurse forever.
final class IOSI2LoopbackHttpOverrides extends HttpOverrides {
  IOSI2LoopbackHttpOverrides({this.denyProxyPort = 9}) {
    if (denyProxyPort < 1 || denyProxyPort > 65535) {
      throw ArgumentError('invalid_i2_deny_proxy_port');
    }
  }

  final int denyProxyPort;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = (uri) =>
        uri.host == '127.0.0.1' &&
            (uri.scheme == 'http' || uri.scheme == 'https')
        ? 'DIRECT'
        : 'PROXY 127.0.0.1:$denyProxyPort';
    return client;
  }
}
