import 'dart:io';

import 'package:flutter/widgets.dart';

import 'native.dart';
import 'ui.dart';

/// A film, episode or other program in a row, from Plex or another app.
class ShowItem {
  const ShowItem({
    required this.title,
    required this.link,
    required this.app,
    this.subtitle,
    this.summary,
    this.image,
    this.progress,
    this.minutesLeft,
  });

  /// The film, or for an episode its show.
  final String title;

  /// "S2 E4 · The Bells" for an episode, a film's year.
  final String? subtitle;
  final String? summary;

  /// A wide picture: a web address, or an app's own (content:) address.
  final String? image;

  /// The app's own link to it, and the app it opens in.
  final String link;
  final String app;

  /// How far in it was left, 0 to 1; null when not started.
  final double? progress;
  final int? minutesLeft;
}

/// A row of things to watch: its id in Config.showsOff, its title, and the
/// app it comes from.
typedef ShowRowData = ({String id, String title, String source, List<ShowItem> items});

/// A row of things to watch between the dock and all apps: a heading,
/// 16:9 cards that scroll sideways, and below them what the focused one is.
class ShowRow extends StatefulWidget {
  const ShowRow({
    super.key,
    required this.row,
    required this.pad,
    required this.gap,
    required this.cardWidth,
    required this.onOpen,
  });

  final ShowRowData row;
  final double pad, gap, cardWidth;
  final ValueChanged<ShowItem> onOpen;

  @override
  State<ShowRow> createState() => _ShowRowState();
}

class _ShowRowState extends State<ShowRow> {
  /// The card whose details show: the focused one, or the last one focused.
  int _shown = 0;

  /// Focus is in this row. The details show only then, so a row left
  /// behind doesn't keep its card's text on screen.
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final items = widget.row.items;
    final shown = items[_shown.clamp(0, items.length - 1)];
    final cardHeight = widget.cardWidth * 9 / 16;
    final left = shown.minutesLeft;
    final about = [
      ?shown.subtitle,
      if (left != null) left < 60 ? '$left min left' : '${left ~/ 60} h ${left % 60} min left',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(widget.pad, 6, widget.pad, 10),
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: widget.row.title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  // A channel named like its app, as NRK's is, says so once.
                  if (widget.row.source != widget.row.title)
                    TextSpan(
                      text: '  ${widget.row.source}',
                      style: const TextStyle(color: Look.dim),
                    ),
                ],
              ),
              style: Look.label.copyWith(fontSize: 15),
            ),
          ),
          Focus(
            canRequestFocus: false,
            skipTraversal: true,
            onFocusChange: (focused) => setState(() => _active = focused),
            child: SizedBox(
              // Room for a focused card to grow and its name below.
              height: cardHeight * 1.06 + 30,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: EdgeInsets.symmetric(horizontal: widget.pad, vertical: cardHeight * 0.03),
                itemCount: items.length,
                separatorBuilder: (_, _) => SizedBox(width: widget.gap),
                itemBuilder: (context, i) => SizedBox(
                  width: widget.cardWidth,
                  child: _ShowCard(
                    item: items[i],
                    first: i == 0,
                    last: i == items.length - 1,
                    onPressed: () => widget.onOpen(items[i]),
                    onFocused: () {
                      setState(() => _shown = i);
                      // The whole row in view, its heading and details too.
                      reveal(this.context);
                    },
                  ),
                ),
              ),
            ),
          ),
          // The space stays, so rows don't move as focus comes and goes.
          AnimatedOpacity(
            opacity: _active ? 1 : 0,
            duration: Look.fast,
            child: Padding(
              padding: EdgeInsets.fromLTRB(widget.pad, 4, widget.pad, 0),
              child: SizedBox(
                height: 52,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (about.isNotEmpty)
                      Text(about.join(' · '), maxLines: 1, style: Look.caption.copyWith(fontSize: 13)),
                    if (shown.summary case final summary?)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          summary,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Look.caption.copyWith(color: const Color(0xA6FFFFFF)),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A film or episode: its picture, how far it was watched, its name below.
/// Focus lifts it and rings it in white, like an app.
class _ShowCard extends StatelessWidget {
  const _ShowCard({
    required this.item,
    required this.first,
    required this.last,
    required this.onPressed,
    required this.onFocused,
  });

  final ShowItem item;

  /// At an end of its row.
  final bool first, last;
  final VoidCallback onPressed;
  final VoidCallback onFocused;

  @override
  Widget build(BuildContext context) => Pressable(
    onPressed: onPressed,
    onKey: (event) => rowEnd(event, first: first, last: last),
    onFocusChange: (focused) {
      if (!focused) return;
      // In view across too, however focus came (Down from the dock, back from an app).
      reveal(context);
      onFocused();
    },
    builder: (context, focused) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AnimatedScale(
          scale: focused ? 1.06 : 1,
          duration: Look.fast,
          curve: Look.ease,
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(color: const Color(0x1FFFFFFF), borderRadius: BorderRadius.circular(10)),
              foregroundDecoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: focused ? Border.all(color: Look.white, width: 2) : null,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.image case final image?) _Picture(image),
                  // A dark line inside the white ring, so it shows on white pictures too.
                  if (focused)
                    Padding(
                      padding: const EdgeInsets.all(2),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: const Color(0x73000000)),
                        ),
                      ),
                    ),
                  if (item.progress case final progress?)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 5,
                      // On a dark track, with a dark line above it, so it shows on white pictures too.
                      child: ColoredBox(
                        color: const Color(0x99000000),
                        child: FractionallySizedBox(
                          alignment: Alignment.centerLeft,
                          widthFactor: progress.clamp(0.02, 1.0),
                          child: const Padding(
                            padding: EdgeInsets.only(top: 1),
                            child: ColoredBox(color: Look.white),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Look.label.copyWith(color: focused ? Look.white : const Color(0xCCFFFFFF)),
        ),
      ],
    ),
  );
}

/// A card's picture: from the web, or from an app's own address, which
/// Android reads for GTVL.
class _Picture extends StatelessWidget {
  const _Picture(this.address);

  final String address;

  /// App pictures as files, looked up once each.
  static final _files = <String, Future<String?>>{};

  @override
  Widget build(BuildContext context) {
    if (address.startsWith('https://') || address.startsWith('http://')) {
      return Image.network(address, fit: BoxFit.cover, cacheWidth: 480, frameBuilder: _fadeIn, errorBuilder: _blank);
    }
    return FutureBuilder(
      future: _files.putIfAbsent(address, () => Native.picture(address)),
      builder: (context, file) => switch (file.data) {
        final String path => Image.file(File(path), fit: BoxFit.cover, frameBuilder: _fadeIn, errorBuilder: _blank),
        _ => const SizedBox.shrink(),
      },
    );
  }

  static Widget _fadeIn(BuildContext context, Widget child, int? frame, bool sync) =>
      sync ? child : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: Look.medium, child: child);

  static Widget _blank(BuildContext context, Object error, StackTrace? stackTrace) => const SizedBox.shrink();
}
