/// A remote connected now, as Native.buttons lists it: its id (vendor and
/// product), its name, the buttons Android says it has, and whether it has
/// sent GTVL a key.
typedef Remote = ({String id, String name, List<String> keys, bool used});

/// Whether the button service is on, and the remotes connected now.
typedef ButtonState = ({bool on, List<Remote> remotes});

/// The remotes [connected] now and any with changes kept from before in
/// [remaps], by id: each one's name and buttons.
Map<String, (String, Set<String>)> remotesOf(List<Remote> connected, Remaps remaps) {
  final remotes = <String, (String, Set<String>)>{
    for (final remote in connected) remote.id: (remote.name, {...remote.keys}),
  };
  for (final (id, name, keys) in remaps.saved) {
    final (_, known) = remotes.putIfAbsent(id, () => (name, <String>{}));
    known.addAll(keys);
  }
  return remotes;
}

/// [action] as the remapper names it: an app by [appName] (null for an app
/// that's gone: its package); null is Default.
String actionLabel(String? action, String? Function(String package) appName) {
  if (action == null) return 'Default';
  if (action == 'nothing') return 'Nothing';
  if (action.startsWith('app:')) return appName(action.substring(4)) ?? action.substring(4);
  for (final (_, actions) in actionGroups) {
    for (final (value, label) in actions) {
      if (value == action) return label;
    }
  }
  return action;
}

/// What [key] on [remote] does instead, in a few words; null when nothing.
String? changeSummary(Remaps remaps, String remote, String key, String? Function(String package) appName) =>
    switch (remaps.changes(remote, key)) {
      [] => null,
      [('press', final action)] => actionLabel(action, appName),
      [(final slot, final action)] => '${slotLabel(slot)}: ${actionLabel(action, appName)}',
      final changes => '${changes.length} changes',
    };

/// [slot] as the remapper names it: Press, Hold or Double press.
String slotLabel(String slot) => slots.firstWhere((s) => s.$1 == slot).$2;

/// A remote's button, by Android's name for it ("BUTTON_12"), as GTVL lists it.
class ButtonInfo {
  const ButtonInfo(this.label, {this.replay = false, this.holdOnly = false});

  final String label;

  /// Its own press still happens after GTVL has held the button back to
  /// time a hold or a double press. Only these buttons can do that (see
  /// ButtonService.replay); the others need their press changed first.
  final bool replay;

  /// Home and Back: their own press always works, so the TV can't lock you
  /// out; only holding them can do something else.
  final bool holdOnly;
}

/// What a button's press, hold and double press can be set to.
const slots = [('press', 'Press'), ('hold', 'Hold'), ('double', 'Double press')];

/// The buttons GTVL looks for on each remote, in the order they are listed.
/// Android's own names; any other button can be found by pressing it.
const knownButtons = <String, ButtonInfo>{
  'FEATURED_APP_1': ButtonInfo('App button 1'),
  'FEATURED_APP_2': ButtonInfo('App button 2'),
  'FEATURED_APP_3': ButtonInfo('App button 3'),
  'FEATURED_APP_4': ButtonInfo('App button 4'),
  'VIDEO_APP_1': ButtonInfo('Video app 1'),
  'VIDEO_APP_2': ButtonInfo('Video app 2'),
  'VIDEO_APP_3': ButtonInfo('Video app 3'),
  'VIDEO_APP_4': ButtonInfo('Video app 4'),
  'BUTTON_1': ButtonInfo('Button 1'),
  'BUTTON_2': ButtonInfo('Button 2'),
  'BUTTON_3': ButtonInfo('Button 3'),
  'BUTTON_4': ButtonInfo('Button 4'),
  'BUTTON_5': ButtonInfo('Button 5'),
  'BUTTON_6': ButtonInfo('Button 6'),
  'BUTTON_7': ButtonInfo('Button 7'),
  'BUTTON_8': ButtonInfo('Button 8'),
  'BUTTON_9': ButtonInfo('Button 9'),
  'BUTTON_10': ButtonInfo('Button 10'),
  'BUTTON_11': ButtonInfo('Button 11'),
  'BUTTON_12': ButtonInfo('Button 12'),
  'MENU': ButtonInfo('Menu'),
  'ASSIST': ButtonInfo('Assistant', replay: true),
  'VOICE_ASSIST': ButtonInfo('Voice', replay: true),
  'SEARCH': ButtonInfo('Search', replay: true),
  'SETTINGS': ButtonInfo('Settings', replay: true),
  'APP_SWITCH': ButtonInfo('Recent apps', replay: true),
  'ALL_APPS': ButtonInfo('All apps'),
  'TV_INPUT': ButtonInfo('Input'),
  'GUIDE': ButtonInfo('Guide'),
  'TV': ButtonInfo('Live TV'),
  'DVR': ButtonInfo('Recordings'),
  'INFO': ButtonInfo('Info'),
  'CAPTIONS': ButtonInfo('Subtitles'),
  'MEDIA_AUDIO_TRACK': ButtonInfo('Audio track'),
  'BOOKMARK': ButtonInfo('Bookmark'),
  'PROG_RED': ButtonInfo('Red'),
  'PROG_GREEN': ButtonInfo('Green'),
  'PROG_YELLOW': ButtonInfo('Yellow'),
  'PROG_BLUE': ButtonInfo('Blue'),
  'MEDIA_PLAY_PAUSE': ButtonInfo('Play/pause', replay: true),
  'MEDIA_PLAY': ButtonInfo('Play', replay: true),
  'MEDIA_PAUSE': ButtonInfo('Pause', replay: true),
  'MEDIA_STOP': ButtonInfo('Stop', replay: true),
  'MEDIA_REWIND': ButtonInfo('Rewind', replay: true),
  'MEDIA_FAST_FORWARD': ButtonInfo('Fast-forward', replay: true),
  'MEDIA_PREVIOUS': ButtonInfo('Previous', replay: true),
  'MEDIA_NEXT': ButtonInfo('Next', replay: true),
  'MEDIA_RECORD': ButtonInfo('Record', replay: true),
  'CHANNEL_UP': ButtonInfo('Channel up'),
  'CHANNEL_DOWN': ButtonInfo('Channel down'),
  'VOLUME_UP': ButtonInfo('Volume up', replay: true),
  'VOLUME_DOWN': ButtonInfo('Volume down', replay: true),
  'VOLUME_MUTE': ButtonInfo('Mute', replay: true),
  'HOME': ButtonInfo('Home', replay: true, holdOnly: true),
  'BACK': ButtonInfo('Back', replay: true, holdOnly: true),
};

/// The SHIELD Remote (2019), by vendor and product.
const shieldRemote = '0955:7217';

/// Remotes whose buttons have names of their own.
const _remoteButtons = {
  shieldRemote: {
    // The Shield opens Netflix for it, and GTVL can too.
    'BUTTON_12': ButtonInfo('Netflix', replay: true),
    'MENU': ButtonInfo('Menu ☰'),
    'ASSIST': ButtonInfo('Voice', replay: true),
  },
};

/// How GTVL lists [key] on [remote]. Buttons it doesn't know are named from
/// Android's name for them, or their scan code.
ButtonInfo buttonInfo(String remote, String key) =>
    _remoteButtons[remote]?[key] ??
    knownButtons[key] ??
    ButtonInfo(
      key.startsWith('SCAN_')
          ? 'Button ${key.substring(5)}'
          : key[0] + key.substring(1).toLowerCase().replaceAll('_', ' '),
    );

/// A remote's [name] as Android gives it ("BT_RC833A_B3 Consumer Control",
/// "virtual-remote"), tidied for reading: no underscores or dashes, no
/// interface name at the end, a capital first letter.
String remoteName(String name) {
  final tidy = name
      .replaceAll(RegExp('[_-]+'), ' ')
      .replaceAll(RegExp(r'\s+(consumer control|keyboard|keypad)$', caseSensitive: false), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  return tidy.isEmpty ? 'Remote' : tidy[0].toUpperCase() + tidy.substring(1);
}

/// Lists [keys] in [knownButtons]' order, then any others by name.
List<String> inButtonOrder(Iterable<String> keys) {
  final order = knownButtons.keys.toList();
  int rank(String key) => order.contains(key) ? order.indexOf(key) : order.length;
  return keys.toSet().toList()..sort((a, b) => rank(a) != rank(b) ? rank(a) - rank(b) : a.compareTo(b));
}

/// What a button can do instead, in the groups the picker shows; besides
/// these, nothing, or opening an app ("app:" and its package). The values
/// are what config.json keeps and ButtonService.perform does.
const actionGroups = <(String, List<(String, String)>)>[
  ('GTVL', [('gtvl:settings', 'GTVL settings'), ('gtvl:apps', 'All apps')]),
  (
    'System',
    [
      ('system:home', 'Home'),
      ('system:back', 'Back'),
      ('system:recents', 'Recent apps'),
      ('system:assistant', 'Assistant'),
      ('system:settings', 'Android settings'),
      ('system:power', 'Power menu'),
      ('system:sleep', 'Sleep'),
      ('system:screenshot', 'Screenshot'),
    ],
  ),
  (
    'Media',
    [
      ('media:play_pause', 'Play/pause'),
      ('media:rewind', 'Rewind'),
      ('media:fast_forward', 'Fast-forward'),
      ('media:previous', 'Previous'),
      ('media:next', 'Next'),
      ('media:stop', 'Stop'),
    ],
  ),
  ('Volume', [('volume:up', 'Volume up'), ('volume:down', 'Volume down'), ('volume:mute', 'Mute')]),
];

/// The remaps, as config.json keeps them under "remotes": each remote's
/// name, and its buttons, each with what its press, hold and double press do
/// instead. A button found but not changed keeps an empty entry, so it stays
/// listed.
class Remaps {
  Remaps(this._remotes);

  final Map<String, Object?> _remotes;

  /// The remotes kept, as (id, name, buttons).
  Iterable<(String, String, List<String>)> get saved sync* {
    for (final MapEntry(key: id, :value) in _remotes.entries) {
      if (value case {'name': final String name, 'buttons': final Map<String, Object?> buttons}) {
        yield (id, name, buttons.keys.toList());
      }
    }
  }

  Map<String, Object?>? _slots(String remote, String key) => switch (_remotes[remote]) {
    {'buttons': final Map<String, Object?> buttons} => switch (buttons[key]) {
      final Map<String, Object?> slots => slots,
      _ => null,
    },
    _ => null,
  };

  /// What [slot] of [key] on [remote] does instead; null when it does its own thing.
  String? action(String remote, String key, String slot) => switch (_slots(remote, key)?[slot]) {
    final String action when action != 'default' => action,
    _ => null,
  };

  /// The slots of [key] that do something else, as (slot, action).
  List<(String, String)> changes(String remote, String key) => [
    for (final (slot, _) in slots)
      if (action(remote, key, slot) case final action?) (slot, action),
  ];

  /// Sets [slot] of [key] on [remote] (named [name]) to [action]; null puts
  /// back the button's own.
  void set(String remote, String name, String key, String slot, String? action) {
    final slots = _entry(remote, name, key);
    if (action == null) {
      slots.remove(slot);
    } else {
      slots[slot] = action;
    }
  }

  /// Sets [slot] of [key] as the remapper does: a button whose own press
  /// can't be made again (see ButtonInfo.replay) loses its hold and double
  /// press with its changed press.
  void assign(String remote, String name, String key, String slot, String? action) {
    set(remote, name, key, slot, action);
    if (slot == 'press' && action == null && !buttonInfo(remote, key).replay) {
      set(remote, name, key, 'hold', null);
      set(remote, name, key, 'double', null);
    }
  }

  /// Whether [slot] of [key] can be changed: Home and Back keep their press,
  /// and have no double press; a hold or a double press needs the button's
  /// own press to be one GTVL can make again after waiting to tell them
  /// apart, or the press changed.
  bool canChange(String remote, String key, String slot) {
    final info = buttonInfo(remote, key);
    if (slot == 'press') return !info.holdOnly;
    if (info.holdOnly) return slot == 'hold';
    return info.replay || action(remote, key, 'press') != null;
  }

  /// Keeps [key] listed under [remote], changed or not.
  void keep(String remote, String name, String key) => _entry(remote, name, key);

  /// Puts back everything [key] on [remote] does.
  void reset(String remote, String key) => _slots(remote, key)?.clear();

  Map<String, Object?> _entry(String remote, String name, String key) {
    final entry = switch (_remotes[remote]) {
      final Map<String, Object?> entry => entry,
      _ => _remotes[remote] = <String, Object?>{},
    };
    entry['name'] = name;
    final buttons = switch (entry['buttons']) {
      final Map<String, Object?> buttons => buttons,
      _ => entry['buttons'] = <String, Object?>{},
    };
    return switch (buttons[key]) {
      final Map<String, Object?> slots => slots,
      _ => buttons[key] = <String, Object?>{},
    };
  }
}
