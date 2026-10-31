import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'home.dart';
import 'services.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Tiles are decoded at the size they are drawn, so a small cache holds them all.
  PaintingBinding.instance.imageCache
    ..maximumSize = 300
    ..maximumSizeBytes = 32 << 20;
  HardwareKeyboard.instance.addHandler(_escape);
  runApp(GtvlApp(services: await Services.start()));
}

final _navigator = GlobalKey<NavigatorState>();

/// A keyboard's Esc (the emulator's, say) does what the remote's Back does,
/// which Android only does for keyboards that map it to Back.
bool _escape(KeyEvent event) {
  if (event.logicalKey != LogicalKeyboardKey.escape) return false;
  if (event is KeyDownEvent) _navigator.currentState?.maybePop();
  return true;
}

class GtvlApp extends StatelessWidget {
  const GtvlApp({super.key, required this.services});

  final Services services;

  @override
  Widget build(BuildContext context) => Scope(
    services: services,
    child: WidgetsApp(
      navigatorKey: _navigator,
      title: 'GTVL',
      color: const Color(0xFF000000),
      debugShowCheckedModeBanner: false,
      textStyle: Look.body,
      shortcuts: {
        ...WidgetsApp.defaultShortcuts,
        const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
      },
      pageRouteBuilder: <T>(RouteSettings settings, WidgetBuilder builder) =>
          PageRouteBuilder<T>(settings: settings, pageBuilder: (context, _, _) => builder(context)),
      home: const HomeScreen(),
    ),
  );
}
