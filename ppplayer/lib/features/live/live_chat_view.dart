import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/live/live_chat.dart';
import '../../core/theme/ultratube_theme.dart';
import '../ultratube/yt_widgets.dart' show compactCount;

// ------------------------------------------------------------- line text

/// Rich text for one chat line: badges, coloured name, text and emotes.
InlineSpan chatLineSpan(ChatMessage m, {double fontSize = 13.5, bool shadow = false, bool showAuthor = true}) {
  final shadows = shadow ? const [Shadow(blurRadius: 3, color: Colors.black)] : null;
  final emoteSize = fontSize * 1.6;
  return TextSpan(
    style: TextStyle(fontSize: fontSize, color: Colors.white, height: 1.3, shadows: shadows),
    children: [
      for (final b in m.badges)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 3),
            child: CachedNetworkImage(imageUrl: b, width: fontSize * 1.15, height: fontSize * 1.15, errorWidget: (_, _, _) => const SizedBox.shrink()),
          ),
        ),
      if (m.isOwner || m.isModerator)
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Padding(
            padding: const EdgeInsets.only(right: 3),
            child: Icon(m.isOwner ? Icons.videocam_rounded : Icons.shield_rounded, size: fontSize * 1.1, color: m.color),
          ),
        ),
      if (showAuthor)
        TextSpan(
          text: '${m.author}  ',
          style: TextStyle(fontWeight: FontWeight.w700, color: m.color ?? const Color(0xFFBDBDBD)),
        ),
      for (final p in m.parts)
        if (p.emote != null)
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Semantics(
              label: p.text,
              child: CachedNetworkImage(
                imageUrl: p.emote!,
                height: emoteSize,
                fadeInDuration: Duration.zero,
                errorWidget: (_, _, _) => Text(p.text, style: TextStyle(fontSize: fontSize, color: Colors.white)),
              ),
            ),
          )
        else
          TextSpan(text: p.text),
    ],
  );
}

// ----------------------------------------------------------- overlay

/// Chat drawn over the video, YouTube/Twitch-theatre style: the newest lines
/// in the lower-left corner with an adjustable translucent backing. It never
/// takes touches, so the player's gestures keep working underneath.
class LiveChatOverlay extends ConsumerStatefulWidget {
  const LiveChatOverlay({super.key, required this.feed, this.maxLines = 7, this.widthFactor = 0.62});
  final ChatFeed feed;
  final int maxLines;

  /// Portion of the video width the column may use.
  final double widthFactor;

  @override
  ConsumerState<LiveChatOverlay> createState() => _LiveChatOverlayState();
}

class _LiveChatOverlayState extends ConsumerState<LiveChatOverlay> {
  /// Lines older than this fade away, so a quiet chat clears the picture.
  static const _ttl = Duration(seconds: 25);
  final _arrived = <String, DateTime>{};
  Timer? _sweep;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_changed);
    _sweep = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant LiveChatOverlay old) {
    super.didUpdateWidget(old);
    if (old.feed != widget.feed) {
      old.feed.removeListener(_changed);
      widget.feed.addListener(_changed);
      _arrived.clear();
    }
  }

  void _changed() {
    final now = DateTime.now();
    for (final m in widget.feed.messages.reversed.take(widget.maxLines)) {
      _arrived.putIfAbsent(m.id, () => now);
    }
    if (_arrived.length > 300) _arrived.removeWhere((_, t) => now.difference(t) > _ttl);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.feed.removeListener(_changed);
    _sweep?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final prefs = ref.watch(liveChatPrefsProvider);
    final now = DateTime.now();
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final lines = [
      for (final m in widget.feed.messages.reversed.take(widget.maxLines))
        if (now.difference(_arrived[m.id] ?? now) < _ttl) m,
    ].reversed.toList();
    final fontSize = 12.5 * prefs.fontScale;
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, box) => Align(
          alignment: Alignment.bottomLeft,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: box.maxWidth * widget.widthFactor, maxHeight: box.maxHeight * 0.62),
            child: ShaderMask(
              // Soft fade at the top edge instead of a hard cut.
              shaderCallback: (r) => const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Colors.black],
                stops: [0, 0.18],
              ).createShader(r),
              blendMode: BlendMode.dstIn,
              child: SingleChildScrollView(
                reverse: true,
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final m in lines)
                      _OverlayLine(
                        key: ValueKey(m.id),
                        message: m,
                        fontSize: fontSize,
                        opacity: prefs.opacity,
                        animate: !reduceMotion,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OverlayLine extends StatelessWidget {
  const _OverlayLine({super.key, required this.message, required this.fontSize, required this.opacity, required this.animate});
  final ChatMessage message;
  final double fontSize;
  final double opacity;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    final highlight = message.highlight != null;
    final line = Container(
      margin: const EdgeInsets.only(top: 3),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: highlight
            ? (message.highlightColor ?? UT.red).withValues(alpha: (opacity + 0.25).clamp(0.35, 0.95))
            : Colors.black.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(UT.rSm),
      ),
      child: Text.rich(
        TextSpan(
          children: [
            if (highlight)
              TextSpan(
                text: '${message.highlight}  ',
                style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, color: Colors.white),
              ),
            chatLineSpan(message, fontSize: fontSize, shadow: opacity < 0.35),
          ],
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (!animate) return line;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: UT.curve,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, (1 - t) * 8), child: child),
      ),
      child: line,
    );
  }
}

// ------------------------------------------------------------- panel

/// Full scrolling chat (below the video in portrait, or in a sheet). Sticks
/// to the newest line unless the user scrolls up to read.
class LiveChatPanel extends StatefulWidget {
  const LiveChatPanel({super.key, required this.feed, this.emptyLabel = 'Aguardando mensagens…', this.controller});
  final ChatFeed feed;
  final String emptyLabel;
  final ScrollController? controller;
  @override
  State<LiveChatPanel> createState() => _LiveChatPanelState();
}

class _LiveChatPanelState extends State<LiveChatPanel> {
  late final ScrollController _scroll = widget.controller ?? ScrollController();
  bool _follow = true;
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    widget.feed.addListener(_changed);
    _scroll.addListener(() {
      if (!_scroll.hasClients) return;
      final atBottom = _scroll.position.pixels <= 24;
      if (atBottom != _follow) setState(() => _follow = atBottom);
      if (atBottom && _unread > 0) setState(() => _unread = 0);
    });
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!_follow) _unread++;
    });
  }

  @override
  void dispose() {
    widget.feed.removeListener(_changed);
    if (widget.controller == null) _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final feed = widget.feed;
    final items = feed.messages;
    return Stack(
      children: [
        if (items.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(UT.s6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(feed.error != null ? Icons.speaker_notes_off_outlined : Icons.forum_outlined, color: UT.text3, size: 32),
                  const SizedBox(height: UT.s2),
                  Text(
                    feed.error ?? (feed.connected ? widget.emptyLabel : 'Conectando ao chat…'),
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: UT.text2),
                  ),
                ],
              ),
            ),
          )
        else
          // Reversed list: index 0 is the newest line at the bottom.
          ListView.builder(
            controller: _scroll,
            reverse: true,
            padding: const EdgeInsets.fromLTRB(UT.s3, UT.s2, UT.s3, UT.s2),
            itemCount: items.length,
            itemBuilder: (context, i) => _PanelLine(items[items.length - 1 - i]),
          ),
        if (_unread > 0)
          Positioned(
            bottom: UT.s3,
            left: 0,
            right: 0,
            child: Center(
              child: ActionChip(
                avatar: const Icon(Icons.arrow_downward_rounded, size: 16),
                label: Text('$_unread ${_unread == 1 ? 'nova mensagem' : 'novas mensagens'}'),
                backgroundColor: UT.surface3,
                onPressed: () {
                  _scroll.animateTo(0, duration: UT.motion, curve: UT.curve);
                  setState(() => _unread = 0);
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _PanelLine extends StatelessWidget {
  const _PanelLine(this.m);
  final ChatMessage m;
  @override
  Widget build(BuildContext context) {
    final text = Text.rich(chatLineSpan(m, fontSize: 13.5));
    if (m.highlight == null) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: text);
    }
    final color = m.highlightColor ?? UT.red;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.22), borderRadius: BorderRadius.circular(UT.rSm), border: Border.all(color: color.withValues(alpha: 0.6))),
      padding: const EdgeInsets.all(UT.s2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(m.highlight!, style: TextStyle(fontWeight: FontWeight.w800, color: color.computeLuminance() < 0.25 ? Colors.white : color)),
          if (m.parts.isNotEmpty || m.author.isNotEmpty) ...[const SizedBox(height: 2), text],
        ],
      ),
    );
  }
}

// --------------------------------------------------------- live badges

/// Red "AO VIVO" pill; greyed with "Voltar ao vivo" when behind the edge.
class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key, this.behind = false, this.onTap, this.label = 'AO VIVO'});
  final bool behind;
  final VoidCallback? onTap;
  final String label;
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label: behind ? 'Voltar ao vivo' : 'Ao vivo',
    child: Material(
      color: behind ? Colors.black54 : UT.red,
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap == null
            ? null
            : () {
                HapticFeedback.selectionClick();
                onTap!();
              },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.circle, size: 8, color: behind ? Colors.white54 : Colors.white),
              const SizedBox(width: 5),
              Text(
                behind ? 'VOLTAR AO VIVO' : label,
                style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w800, letterSpacing: 0.4),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// "1,2 mil assistindo" chip; hidden when the counter is turned off or the
/// number is still unknown.
class ViewerCountChip extends ConsumerWidget {
  const ViewerCountChip({super.key, required this.viewers, this.onTap});
  final ValueListenable<int> viewers;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(liveChatPrefsProvider.select((p) => p.showViewers))) return const SizedBox.shrink();
    return ValueListenableBuilder<int>(
      valueListenable: viewers,
      builder: (context, n, _) => n < 0
          ? const SizedBox.shrink()
          : GestureDetector(
              onTap: onTap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(4)),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.person_outline_rounded, size: 14, color: Colors.white),
                    const SizedBox(width: 4),
                    AnimatedSwitcher(
                      duration: UT.motion,
                      child: Text(
                        compactCount(n),
                        key: ValueKey(n),
                        style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ------------------------------------------------------------ settings

Future<void> showLiveChatSettings(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  backgroundColor: UT.surface1,
  builder: (_) => const _LiveChatSettings(),
);

class _LiveChatSettings extends ConsumerWidget {
  const _LiveChatSettings();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(liveChatPrefsProvider);
    final notifier = ref.read(liveChatPrefsProvider.notifier);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s2),
            child: Text('Chat ao vivo', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.chat_bubble_outline_rounded),
            title: const Text('Chat sobre o vídeo'),
            subtitle: const Text('Mensagens transparentes no canto do player'),
            value: prefs.overlay,
            onChanged: (v) => notifier.update(prefs.copyWith(overlay: v)),
          ),
          ListTile(
            enabled: prefs.overlay,
            leading: const Icon(Icons.opacity_rounded),
            title: const Text('Fundo das mensagens'),
            subtitle: Slider(
              value: prefs.opacity,
              max: 0.9,
              divisions: 9,
              label: '${(prefs.opacity * 100).round()}%',
              onChanged: prefs.overlay ? (v) => notifier.update(prefs.copyWith(opacity: v)) : null,
            ),
          ),
          ListTile(
            enabled: prefs.overlay,
            leading: const Icon(Icons.format_size_rounded),
            title: const Text('Tamanho do texto'),
            subtitle: Slider(
              value: prefs.fontScale,
              min: 0.8,
              max: 1.5,
              divisions: 7,
              label: '${(prefs.fontScale * 100).round()}%',
              onChanged: prefs.overlay ? (v) => notifier.update(prefs.copyWith(fontScale: v)) : null,
            ),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.groups_outlined),
            title: const Text('Contador de espectadores'),
            subtitle: const Text('Mostra quantas pessoas estão assistindo agora'),
            value: prefs.showViewers,
            onChanged: (v) => notifier.update(prefs.copyWith(showViewers: v)),
          ),
          const SizedBox(height: UT.s4),
        ],
      ),
    );
  }
}
