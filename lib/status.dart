import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'config.dart';
import 'native.dart';

typedef VpnApp = ({String package, String name});

/// Network and VPN state, and the installed VPN apps, for the top bar.
class StatusModel extends ChangeNotifier with WidgetsBindingObserver {
  StatusModel(this._config) {
    Native.events.where((event) => event['type'] == 'network').listen((event) {
      kind = event['kind'] as String? ?? 'none';
      online = event['online'] == true;
      vpn = event['vpn'] == true;
      signal = event['signal'] as int? ?? _unknown;
      notifyListeners();
    });
    // Look for VPN apps again whenever the launcher comes back to the front,
    // which covers apps installed or removed meanwhile.
    WidgetsBinding.instance.addObserver(this);
    refreshVpnApps();
  }

  final Config _config;
  static const _unknown = -2147483648; // Android's "no signal strength"

  /// none, wifi, ethernet, cellular or other.
  String kind = 'none';
  bool online = false;
  bool vpn = false;

  /// Wi-Fi strength in dBm.
  int signal = _unknown;
  List<VpnApp> vpnApps = const [];

  /// The chosen VPN app, or the first one installed.
  VpnApp? get vpnApp =>
      vpnApps.isEmpty ? null : vpnApps.firstWhere((app) => app.package == _config.vpnApp, orElse: () => vpnApps.first);

  IconData get networkIcon => switch (kind) {
    'ethernet' => Icons.settings_ethernet,
    'wifi' => const [
      Icons.signal_wifi_0_bar,
      Icons.network_wifi_1_bar,
      Icons.network_wifi_2_bar,
      Icons.network_wifi_3_bar,
      Icons.signal_wifi_4_bar,
    ][_bars],
    'none' => Icons.signal_wifi_off,
    _ => Icons.public,
  };

  int get _bars => switch (signal) {
    _unknown => 4,
    >= -55 => 4,
    >= -66 => 3,
    >= -77 => 2,
    >= -88 => 1,
    _ => 0,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshVpnApps();
  }

  Future<void> refreshVpnApps() async {
    vpnApps = [for (final m in await Native.vpnApps()) (package: m['package']! as String, name: m['name']! as String)];
    notifyListeners();
  }
}
