import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';

import 'apps.dart';
import 'buttons.dart';
import 'native.dart';
import 'panel.dart';
import 'services.dart';
import 'tile.dart';
import 'ui.dart';

/// Opens the button remapper over the screen. It listens for the button to
/// change, pressed on the remote, or picked from a list; then shows what its
/// press, hold and double press do, and lets each do something else. With
/// [button], it opens on that button.
Future<void> showRemapper(BuildContext context, {RemoteButton? button}) =>
    showPanel(context, (context) => _Remapper(button: button));

/// A button: its remote's id and name, and Android's name for the button.
typedef RemoteButton = ({String remote, String name, String key});

/// What the remapper shows, each over the one before; Back goes back up.
sealed class _View {
  const _View();
}

/// Waiting for the button to change; the buttons changed so far.
final class _Listen extends _View {
  const _Listen();
}

/// The remotes, to pick a button from a list.
final class _Remotes extends _View {
  const _Remotes();
}

/// One remote's buttons.
final class _RemoteKeys extends _View {
  _RemoteKeys(this.remote);

  final String remote;
}

/// One button: what its press, hold and double press do.
final class _Button extends _View {
  _Button(this.button);

  final RemoteButton button;
}

/// What one of a button's press, hold or double press does: the choices.
final class _Choose extends _View {
  _Choose(this.button, this.slot);

  final RemoteButton button;
  final String slot;
}

class _Remapper extends StatefulWidget {
  const _Remapper({this.button});

  final RemoteButton? button;

  @override
  State<_Remapper> createState() => _RemapperState();
}

class _RemapperState extends State<_Remapper> {
  late final Services s = Services.of(context);
  late final List<_View> _views = [if (widget.button case final button?) _Button(button) else const _Listen()];

  /// Whether the button service is on, and the remotes connected; null until asked.
  ButtonState? _state;
  StreamSubscription<Object?>? _events;
  bool _listening = false;

  /// The row to focus as a view shows: the one that opened the view just closed.
  String? _focus;

  /// Each view's row that opened the view over it.
  final _openedBy = <_View, String>{};

  /// Coming back from Android settings, where the button service is turned on.
  late final _lifecycle = AppLifecycleListener(onResume: _refresh);

  /// A button's Done, which takes focus when Reset goes.
  final _done = FocusNode(debugLabel: 'Done');

  @override
  void initState() {
    super.initState();
    _events = Native.events.where((event) => event['type'] == 'buttons').listen((_) => _refresh());
    _lifecycle;
    _refresh();
  }

  @override
  void dispose() {
    _events?.cancel();
    _lifecycle.dispose();
    _done.dispose();
    if (_listening) Native.stopFinding();
    super.dispose();
  }

  Remaps get _remaps => Remaps(s.config.remotes);

  Future<void> _refresh() async {
    final state = await Native.buttons(knownButtons.keys.toList());
    if (!mounted) return;
    setState(() => _state = state);
    _listen();
  }

  /// Waits for a press of the button to change while the remapper listens.
  void _listen() {
    if (_listening || !mounted || _views.last is! _Listen || !(_state?.on ?? false)) return;
    _listening = true;
    final asked = DateTime.now();
    Native.findButton().then((found) {
      _listening = false;
      if (!mounted) return;
      if (found == null) {
        // It gives up after a while; listen again. Giving up at once means
        // the service went off: ask again, and listen once it is back.
        if (DateTime.now().difference(asked) > const Duration(seconds: 5)) {
          _listen();
        } else {
          Timer(const Duration(seconds: 1), _refresh);
        }
        return;
      }
      if (_views.last is! _Listen) return;
      _remaps.keep(found.remote, found.name, found.key);
      _save();
      _open(_Button((remote: found.remote, name: found.name, key: found.key)));
    });
  }

  /// Saves the remaps, and hands them to the button service at once.
  void _save() {
    s.config.changed();
    Native.remap(s.config.remotes);
  }

  /// Shows [view] over this one, opened by the row [from].
  void _open(_View view, {String? from}) {
    if (_listening) {
      Native.stopFinding();
      _listening = false;
    }
    setState(() {
      if (from != null) _openedBy[_views.last] = from;
      _views.add(view);
      _focus = null;
    });
  }

  /// Back to the view before, on the row that opened the one closed.
  void _back() {
    if (_views.length == 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _views.removeLast();
      _focus = _openedBy.remove(_views.last);
    });
    _listen();
  }

  String _action(String? action) => actionLabel(action, _appName);

  AppInfo? _app(String? action) {
    if (action == null || !action.startsWith('app:')) return null;
    final package = action.substring(4);
    return s.apps.all.where((app) => app.package == package).firstOrNull;
  }

  String? _appName(String package) => s.apps.all.where((app) => app.package == package).firstOrNull?.label;

  /// What [key] on [remote] does instead, in a few words; null when nothing.
  String? _summary(String remote, String key) => changeSummary(_remaps, remote, key, _appName);

  @override
  Widget build(BuildContext context) {
    final view = _views.last;
    final (:title, :subtitle, :leading, :width, :body, :footer) = switch (view) {
      _Listen() => _listenView(),
      _Remotes() => _remotesView(),
      _RemoteKeys(:final remote) => _remoteKeysView(remote),
      _Button(:final button) => _buttonView(button),
      _Choose(:final button, :final slot) => _chooseView(button, slot),
    };
    return PopScope(
      canPop: _views.length == 1,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Panel(
        title: title,
        subtitle: subtitle,
        leading: leading,
        width: width,
        child: KeyedSubtree(
          key: ObjectKey(view),
          child: _FadeIn(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: FocusTraversalGroup(
                    policy: smoothTraversal,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: body,
                      ),
                    ),
                  ),
                ),
                if (footer.isNotEmpty) ...[
                  const Hairline(),
                  // Side by side, edge to edge, so a button's band runs to the panel's sides.
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(children: [for (final button in footer) Expanded(child: button)]),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Whether the row [id] should take focus as its view shows, being the one
  /// to come back to, or with none, being [first].
  bool _focused(String id, {bool first = false}) => _focus == null ? first : _focus == id;

  _Content _listenView() {
    final on = _state?.on ?? false;
    final remaps = _remaps;
    final remotes = remotesOf(_state?.remotes ?? const [], remaps);
    final changed = [
      for (final MapEntry(key: id, value: (name, keys)) in remotes.entries)
        for (final key in inButtonOrder(keys))
          if (remaps.changes(id, key).isNotEmpty) (remote: id, name: name, key: key),
    ];
    var first = true;
    bool firstRow() {
      final was = first;
      first = false;
      return was;
    }

    return (
      title: _state == null ? ' ' : (on ? 'Press a button' : 'Turn on button remapping'),
      subtitle: _state == null
          ? null
          : on
          ? 'Press the button on your remote that you want to change.'
          : 'In Android settings, go to Device Preferences › Accessibility › Services › GTVL buttons, '
                'and turn it on. On Google TV, Accessibility is under System.',
      leading: _Listening(on: on && _state != null),
      width: 380.0,
      body: [
        if (_state != null && !on)
          _Item(
            'Open Android settings',
            icon: Icons.open_in_new_rounded,
            autofocus: _focused('settings', first: firstRow()),
            onPressed: Native.buttonSettings,
          ),
        if (changed.isNotEmpty) ...[
          const _Heading('Changed'),
          for (final button in changed)
            _Item(
              buttonInfo(button.remote, button.key).label,
              icon: Icons.smart_button_outlined,
              app: _app(remaps.action(button.remote, button.key, 'press')),
              value: _summary(button.remote, button.key),
              note: remotes.length > 1 ? remoteName(button.name) : null,
              chevron: true,
              autofocus: _focused('${button.remote} ${button.key}', first: firstRow()),
              onPressed: () => _open(_Button(button), from: '${button.remote} ${button.key}'),
            ),
          const SizedBox(height: 4),
        ],
        _Item(
          'Choose from a list',
          icon: Icons.format_list_bulleted_rounded,
          chevron: true,
          autofocus: _focused('list', first: firstRow()),
          onPressed: () => _open(const _Remotes(), from: 'list'),
        ),
      ],
      footer: [_FooterButton('Done', onPressed: _back)],
    );
  }

  /// Each remote as a row of its own: TVs list several input devices, most
  /// of them no remote anyone holds, each claiming every button there is.
  /// The one that has sent GTVL keys comes first.
  _Content _remotesView() {
    final remotes = remotesOf(_state?.remotes ?? const [], _remaps);
    final used = {
      for (final remote in _state?.remotes ?? const <Remote>[])
        if (remote.used) remote.id,
    };
    final order = remotes.keys.toList()..sort((a, b) => (used.contains(a) ? 0 : 1) - (used.contains(b) ? 0 : 1));
    return (
      title: 'Choose a button',
      subtitle: remotes.isEmpty ? 'No remote lists its buttons. Find a button by pressing it.' : null,
      leading: null,
      width: 380.0,
      body: [
        for (final (i, id) in order.indexed)
          _Item(
            remoteName(remotes[id]!.$1),
            icon: Icons.settings_remote_outlined,
            note: used.contains(id) ? 'In use' : null,
            chevron: true,
            autofocus: _focused(id, first: i == 0),
            onPressed: () => _open(_RemoteKeys(id), from: id),
          ),
      ],
      // With nothing to choose, something to focus all the same.
      footer: [if (remotes.isEmpty) _FooterButton('Back', onPressed: _back)],
    );
  }

  _Content _remoteKeysView(String id) {
    final remote = remotesOf(_state?.remotes ?? const [], _remaps)[id];
    final keys = remote == null ? const <String>[] : inButtonOrder(remote.$2);
    return (
      title: remote == null ? 'Not connected' : remoteName(remote.$1),
      subtitle: 'Android lists every button this kind of remote could have, so some may not be on yours.',
      leading: null,
      width: 380.0,
      body: [
        for (final (i, key) in keys.indexed)
          _Item(
            buttonInfo(id, key).label,
            value: _summary(id, key),
            chevron: true,
            autofocus: _focused(key, first: i == 0),
            onPressed: () => _open(_Button((remote: id, name: remote!.$1, key: key)), from: key),
          ),
      ],
      footer: [if (keys.isEmpty) _FooterButton('Back', onPressed: _back)],
    );
  }

  _Content _buttonView(RemoteButton button) {
    final info = buttonInfo(button.remote, button.key);
    final remaps = _remaps;
    final changed = remaps.changes(button.remote, button.key).isNotEmpty;
    final timed = remaps.canChange(button.remote, button.key, 'hold');
    final rows = [
      for (final (slot, label) in slots)
        if (!info.holdOnly || slot == 'hold') (slot, label),
    ];
    return (
      title: null,
      subtitle: remoteName(button.name),
      leading: _KeyCap(info.label),
      width: 380.0,
      body: [
        for (final (i, (slot, label)) in rows.indexed)
          _Item(
            label,
            value: _action(remaps.action(button.remote, button.key, slot)),
            app: _app(remaps.action(button.remote, button.key, slot)),
            chevron: true,
            enabled: remaps.canChange(button.remote, button.key, slot),
            autofocus: _focused(slot, first: i == 0),
            onPressed: () => _open(_Choose(button, slot), from: slot),
          ),
        _Notes([
          if (info.holdOnly)
            "Pressing ${info.label} always does its usual job, so you can't get stuck. Only holding it can do "
                'something else.'
          else if (!timed)
            "Hold and Double press need Press changed first: after waiting to tell them apart, GTVL can't send "
                "${info.label}'s own press."
          else
            'With Double press set, a single press waits a moment in case another press follows.',
          if (button.remote == shieldRemote && button.key == 'MENU')
            "If the Shield's own Customize menu button setting is in use, leave ☰ alone here.",
        ]),
      ],
      footer: [
        if (changed)
          _FooterButton(
            'Reset',
            destructive: true,
            onPressed: () {
              remaps.reset(button.remote, button.key);
              _save();
              setState(() {});
              WidgetsBinding.instance
                ..addPostFrameCallback((_) => _done.requestFocus())
                ..scheduleFrame();
            },
          ),
        _FooterButton('Done', focusNode: _done, onPressed: _back),
      ],
    );
  }

  _Content _chooseView(RemoteButton button, String slot) {
    final now = _remaps.action(button.remote, button.key, slot);
    void pick(String? action) {
      _remaps.assign(button.remote, button.name, button.key, slot, action);
      _save();
      _back();
    }

    Widget choice(String? action, String label, {IconData? icon, AppInfo? app}) => _Choice(
      label,
      icon: icon,
      app: app,
      chosen: now == action,
      autofocus: now == action,
      onPressed: () => pick(action),
    );

    final apps = s.apps.all;
    return (
      title: slotLabel(slot),
      subtitle: '${buttonInfo(button.remote, button.key).label} · ${remoteName(button.name)}',
      leading: null,
      width: 520.0,
      body: [
        _Grid(
          columns: 2,
          children: [
            choice(null, 'Default', icon: Icons.undo_rounded),
            choice('nothing', 'Nothing', icon: Icons.block_rounded),
          ],
        ),
        if (apps.isNotEmpty) ...[
          const _Heading('Open an app'),
          _Grid(columns: 5, children: [for (final app in apps) choice('app:${app.package}', app.label, app: app)]),
        ],
        for (final (group, actions) in actionGroups) ...[
          _Heading(group),
          _Grid(
            columns: 3,
            children: [for (final (value, label) in actions) choice(value, label, icon: _actionIcons[value])],
          ),
        ],
      ],
      footer: const <Widget>[],
    );
  }
}

/// What a view of the remapper shows: its header, its width, its rows and
/// the buttons along its foot.
typedef _Content = ({
  String? title,
  String? subtitle,
  Widget? leading,
  double width,
  List<Widget> body,
  List<Widget> footer,
});

/// An icon for each action in [actionGroups].
const _actionIcons = <String, IconData>{
  'gtvl:settings': Icons.tune_rounded,
  'gtvl:apps': Icons.apps_rounded,
  'system:home': Icons.home_outlined,
  'system:back': Icons.arrow_back_rounded,
  'system:recents': Icons.filter_none_rounded,
  'system:assistant': Icons.mic_none_rounded,
  'system:settings': Icons.settings_outlined,
  'system:power': Icons.power_settings_new_rounded,
  'system:sleep': Icons.bedtime_outlined,
  'system:screenshot': Icons.crop_free_rounded,
  'media:play_pause': Icons.play_arrow_rounded,
  'media:rewind': Icons.fast_rewind_rounded,
  'media:fast_forward': Icons.fast_forward_rounded,
  'media:previous': Icons.skip_previous_rounded,
  'media:next': Icons.skip_next_rounded,
  'media:stop': Icons.stop_rounded,
  'volume:up': Icons.volume_up_rounded,
  'volume:down': Icons.volume_down_rounded,
  'volume:mute': Icons.volume_off_rounded,
};

/// A view's content fading in as it takes the place of the one before.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: Look.fast,
    curve: Look.ease,
    child: child,
    builder: (context, t, child) => Opacity(opacity: t, child: child),
  );
}

/// The remote, waiting for a press: rings spread from it while it listens.
class _Listening extends StatefulWidget {
  const _Listening({required this.on});

  final bool on;

  @override
  State<_Listening> createState() => _ListeningState();
}

class _ListeningState extends State<_Listening> with SingleTickerProviderStateMixin {
  late final _rings = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

  @override
  void initState() {
    super.initState();
    if (widget.on) _rings.repeat();
  }

  @override
  void didUpdateWidget(_Listening old) {
    super.didUpdateWidget(old);
    if (widget.on && !_rings.isAnimating) _rings.repeat();
    if (!widget.on) _rings.stop();
  }

  @override
  void dispose() {
    _rings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 76,
    child: CustomPaint(
      painter: widget.on ? _Rings(_rings) : null,
      child: const Center(
        child: SizedBox.square(
          dimension: 52,
          child: DecoratedBox(
            decoration: BoxDecoration(color: Color(0x26FFFFFF), shape: BoxShape.circle),
            child: Icon(Icons.settings_remote_outlined, size: 28, color: Look.white),
          ),
        ),
      ),
    ),
  );
}

/// Two rings spreading out from the remote and fading, half a beat apart.
class _Rings extends CustomPainter {
  _Rings(this.t) : super(repaint: t);

  final Animation<double> t;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    for (final phase in [0.0, 0.5]) {
      final p = (t.value + phase) % 1;
      final eased = Curves.easeOut.transform(p);
      canvas.drawCircle(
        centre,
        26 + 12 * eased,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = Look.white.withValues(alpha: 0.45 * (1 - p)),
      );
    }
  }

  @override
  bool shouldRepaint(_Rings old) => false;
}

/// A button's name on a key, as on the remote.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 64),
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x38FFFFFF), Color(0x1AFFFFFF)],
      ),
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: const Color(0x33FFFFFF)),
      boxShadow: const [BoxShadow(color: Color(0x59000000), blurRadius: 10, offset: Offset(0, 3))],
    ),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: Look.body.copyWith(fontSize: 17, fontWeight: FontWeight.w600, color: Look.white),
    ),
  );
}

/// A quiet heading over a group of rows or choices.
class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
    child: Text(
      text.toUpperCase(),
      style: Look.small.copyWith(
        fontSize: 11,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w600,
        color: const Color(0x8CFFFFFF),
      ),
    ),
  );
}

/// Short notes under a button's rows.
class _Notes extends StatelessWidget {
  const _Notes(this.notes);

  final List<String> notes;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 10, 18, 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final note in notes)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Prose(note, style: Look.small.copyWith(color: const Color(0x99FFFFFF))),
          ),
      ],
    ),
  );
}

/// A row of the remapper: an icon or an app's, its label and a note under
/// it, and what it is set to at the end.
class _Item extends StatelessWidget {
  const _Item(
    this.label, {
    this.icon,
    this.app,
    this.value,
    this.note,
    this.chevron = false,
    this.enabled = true,
    this.autofocus = false,
    required this.onPressed,
  });

  final String label;
  final IconData? icon;

  /// The app [value] opens, whose icon shows beside it.
  final AppInfo? app;
  final String? value;
  final String? note;
  final bool chevron;

  /// False greys the row out: it can still be focused, to read why, but does nothing.
  final bool enabled;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: enabled ? onPressed : null,
    builder: (context, focused) {
      final color = Look.white.withValues(alpha: !enabled ? 0.4 : (focused ? 1 : 0.88));
      final app = this.app;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: FocusBand(
          focused: focused,
          child: Container(
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 7),
            child: Row(
              children: [
                if (icon != null) ...[Icon(icon, size: 18, color: color), const SizedBox(width: 12)],
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label, style: Look.body.copyWith(color: color)),
                      if (note != null)
                        Text(note!, style: Look.small.copyWith(fontSize: 12, color: const Color(0x8CFFFFFF))),
                    ],
                  ),
                ),
                if (app != null) ...[
                  SizedBox.square(
                    dimension: 22,
                    child: ClipRRect(borderRadius: BorderRadius.circular(6), child: TileFace(app, square: true)),
                  ),
                  const SizedBox(width: 8),
                ],
                if (value != null)
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 150),
                    child: Text(
                      value!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Look.value.copyWith(color: focused && enabled ? Look.white : const Color(0xB8FFFFFF)),
                    ),
                  ),
                if (chevron)
                  Icon(
                    Icons.chevron_right_rounded,
                    size: 20,
                    color: Look.white.withValues(alpha: enabled ? 0.6 : 0.25),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

/// Choices in rows of [columns], each as wide as the others.
class _Grid extends StatelessWidget {
  const _Grid({required this.columns, required this.children});

  final int columns;
  final List<Widget> children;

  static const _gap = 8.0;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Column(
      children: [
        for (var i = 0; i < children.length; i += columns)
          Padding(
            padding: const EdgeInsets.only(bottom: _gap),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var j = i; j < i + columns; j++) ...[
                  if (j > i) const SizedBox(width: _gap),
                  Expanded(child: j < children.length ? children[j] : const SizedBox.shrink()),
                ],
              ],
            ),
          ),
      ],
    ),
  );
}

/// One thing a button can do: an icon (or an app's) over its name, ringed in
/// white while it is what the button does.
class _Choice extends StatelessWidget {
  const _Choice(
    this.label, {
    this.icon,
    this.app,
    required this.chosen,
    required this.autofocus,
    required this.onPressed,
  });

  final String label;
  final IconData? icon;
  final AppInfo? app;
  final bool chosen;
  final bool autofocus;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Pressable(
    autofocus: autofocus,
    onPressed: onPressed,
    dip: true,
    builder: (context, focused) {
      final app = this.app;
      // In focus a choice lifts and brightens, as the colour picker's swatches do.
      return AnimatedScale(
        scale: focused ? 1.05 : 1,
        duration: Look.fast,
        curve: Look.ease,
        child: AnimatedContainer(
          duration: Look.fast,
          curve: Look.ease,
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: app != null ? 10 : 12),
          decoration: BoxDecoration(
            color: focused ? const Color(0x2EFFFFFF) : const Color(0x14FFFFFF),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: chosen ? Look.white : const Color(0x00FFFFFF), width: chosen ? 2 : 1),
          ),
          child: app != null
              ? Column(
                  children: [
                    SizedBox.square(
                      dimension: 44,
                      child: ClipRRect(borderRadius: BorderRadius.circular(11), child: TileFace(app, square: true)),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Look.small.copyWith(fontSize: 12, color: Look.white.withValues(alpha: focused ? 1 : 0.85)),
                    ),
                  ],
                )
              : Row(
                  children: [
                    Icon(icon, size: 18, color: Look.white.withValues(alpha: focused ? 1 : 0.85)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Look.body.copyWith(
                          fontSize: 14,
                          color: Look.white.withValues(alpha: focused ? 1 : 0.88),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    },
  );
}

/// A button along the remapper's foot.
class _FooterButton extends StatelessWidget {
  const _FooterButton(this.label, {required this.onPressed, this.destructive = false, this.focusNode});

  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  /// Red, for putting things back.
  final bool destructive;

  @override
  Widget build(BuildContext context) => Pressable(
    focusNode: focusNode,
    onPressed: onPressed,
    builder: (context, focused) => FocusBand(
      focused: focused,
      child: Container(
        constraints: const BoxConstraints(minHeight: 40),
        alignment: Alignment.center,
        child: Text(
          label,
          style: Look.body.copyWith(
            color: (destructive ? Look.danger : Look.white).withValues(alpha: focused ? 1 : 0.88),
          ),
        ),
      ),
    ),
  );
}
