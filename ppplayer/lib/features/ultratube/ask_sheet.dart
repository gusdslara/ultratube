import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ai/video_assistant.dart';
import '../../core/theme/ultratube_theme.dart';

/// Opens the "Perguntar" assistant for the current video. [onSeek] makes
/// the [m:ss] marks in answers tappable.
Future<void> showAskSheet(
  BuildContext context, {
  required VideoContext Function() video,
  void Function(Duration position)? onSeek,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: UT.surface1,
  builder: (_) => _AskSheet(video: video, onSeek: onSeek),
);

/// Sparkle button shown in the watch page actions row.
class AskPill extends StatelessWidget {
  const AskPill({super.key, required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: Material(
      color: UT.surface2,
      shape: const StadiumBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          onTap();
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 18, color: UT.text),
              SizedBox(width: 6),
              Text('Perguntar', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: UT.text)),
            ],
          ),
        ),
      ),
    ),
  );
}

List<String> _suggestionsFor(VideoContext v) => v.live
    ? const ['O que está acontecendo agora?', 'Do que o chat está falando?', 'Resumir a transmissão', 'Quem é este canal?']
    : const ['Resumir o vídeo', 'Quais são os pontos principais?', 'Recomendar conteúdo relacionado', 'Explicar de um jeito simples'];

class _AskSheet extends StatefulWidget {
  const _AskSheet({required this.video, this.onSeek});
  final VideoContext Function() video;
  final void Function(Duration position)? onSeek;
  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  final _assistant = VideoAssistant.instance;
  final _input = TextEditingController();
  final _keyInput = TextEditingController();
  final _scroll = ScrollController();
  final _turns = <AskTurn>[];
  late VideoContext _video = widget.video();
  StreamSubscription<String>? _answer;
  bool? _hasKey;
  bool _editingKey = false;
  bool _savingKey = false;

  @override
  void initState() {
    super.initState();
    _assistant.apiKey().then((k) {
      if (mounted) setState(() => _hasKey = k != null);
    });
    // Warm the captions while the user picks a question.
    if (!_video.live) unawaited(_assistant.transcript(_video.videoId));
  }

  @override
  void dispose() {
    _answer?.cancel();
    _input.dispose();
    _keyInput.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _busy => _turns.isNotEmpty && !_turns.last.done;

  void _ask(String question) {
    question = question.trim();
    if (question.isEmpty || _busy) return;
    HapticFeedback.selectionClick();
    _input.clear();
    _video = widget.video(); // fresh chat lines / counters for lives
    final history = List<AskTurn>.of(_turns);
    final turn = AskTurn(question);
    setState(() => _turns.add(turn));
    _toBottom();
    _answer = _assistant.ask(_video, history, question).listen(
      (chunk) {
        turn.answer += chunk;
        if (mounted) setState(() {});
        _toBottom();
      },
      onError: (Object error) {
        turn
          ..error = '$error'
          ..done = true;
        if (error is AssistantException && error.needsKey) _hasKey = false;
        if (mounted) setState(() {});
      },
      onDone: () {
        turn.done = true;
        if (mounted) setState(() {});
      },
      cancelOnError: true,
    );
  }

  void _stop() {
    _answer?.cancel();
    if (_turns.isNotEmpty) {
      final last = _turns.last;
      last.done = true;
      if (last.answer.isEmpty) last.error = 'Resposta interrompida.';
    }
    setState(() {});
  }

  void _toBottom() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: UT.motion, curve: UT.curve);
  });

  Future<void> _saveKey() async {
    setState(() => _savingKey = true);
    await _assistant.setApiKey(_keyInput.text);
    final ok = await _assistant.apiKey() != null;
    if (!mounted) return;
    setState(() {
      _savingKey = false;
      _hasKey = ok;
      _editingKey = !ok;
    });
    _keyInput.clear();
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.4,
        maxChildSize: 0.95,
        builder: (context, sheetScroll) => Column(
          children: [
            _header(),
            const Divider(height: 1, color: UT.line),
            Expanded(child: _body(sheetScroll)),
            if (_hasKey == true && !_editingKey) _composer(),
          ],
        ),
      ),
    );
  }

  Widget _header() => Padding(
    padding: const EdgeInsets.fromLTRB(UT.s5, 0, UT.s2, UT.s3),
    child: Row(
      children: [
        const Icon(Icons.auto_awesome, color: UT.text, size: 22),
        const SizedBox(width: UT.s3),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Perguntar', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              Text(_video.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, color: UT.text2)),
            ],
          ),
        ),
        PopupMenuButton<String>(
          tooltip: 'Opções',
          icon: const Icon(Icons.more_vert),
          onSelected: (v) async {
            if (v == 'key') setState(() => _editingKey = true);
            if (v == 'clear') {
              _answer?.cancel();
              setState(_turns.clear);
            }
            if (v == 'remove') {
              await _assistant.setApiKey(null);
              if (mounted) setState(() => _hasKey = false);
            }
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'clear', child: Text('Nova conversa')),
            const PopupMenuItem(value: 'key', child: Text('Trocar chave do Gemini')),
            if (_hasKey == true) const PopupMenuItem(value: 'remove', child: Text('Remover chave')),
          ],
        ),
      ],
    ),
  );

  Widget _body(ScrollController sheetScroll) {
    if (_hasKey == null) return const Center(child: CircularProgressIndicator());
    if (_hasKey == false || _editingKey) return _keySetup(sheetScroll);
    final suggestions = _suggestionsFor(_video).where((s) => !_turns.any((t) => t.question == s)).toList();
    return ListView(
      controller: _turns.isEmpty ? sheetScroll : _scroll,
      padding: const EdgeInsets.fromLTRB(UT.s4, UT.s4, UT.s4, UT.s4),
      children: [
        if (_turns.isEmpty) ...[
          const Text('Olá! Pergunte o que quiser sobre este vídeo.', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: UT.s1),
          Text(
            _video.live ? 'Uso o título, a descrição e o chat ao vivo.' : 'Uso as legendas, a descrição e os detalhes do vídeo.',
            style: const TextStyle(color: UT.text2, fontSize: 13),
          ),
          const SizedBox(height: UT.s4),
          for (final s in suggestions) _SuggestionTile(label: s, onTap: () => _ask(s)),
        ],
        for (final t in _turns) ...[
          _QuestionBubble(t.question),
          const SizedBox(height: UT.s3),
          _AnswerView(turn: t, onSeek: widget.onSeek, onRetry: () {
            setState(() => _turns.remove(t));
            _ask(t.question);
          }),
          const SizedBox(height: UT.s4),
        ],
        if (_turns.isNotEmpty && !_busy && suggestions.isNotEmpty)
          Wrap(
            spacing: UT.s2,
            runSpacing: UT.s2,
            children: [
              for (final s in suggestions)
                ActionChip(
                  label: Text(s),
                  backgroundColor: UT.surface2,
                  side: const BorderSide(color: UT.line),
                  shape: const StadiumBorder(),
                  onPressed: () => _ask(s),
                ),
            ],
          ),
        const SizedBox(height: UT.s3),
        const Text(
          'Respostas geradas por IA (Gemini) e podem conter erros.',
          textAlign: TextAlign.center,
          style: TextStyle(color: UT.text3, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _keySetup(ScrollController sheetScroll) => ListView(
    controller: sheetScroll,
    padding: const EdgeInsets.all(UT.s5),
    children: [
      const Text('Conecte o Gemini', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: UT.s2),
      const Text(
        'O Perguntar usa a sua chave gratuita do Google AI Studio. Ela fica guardada só neste aparelho, '
        'no armazenamento seguro, e as perguntas vão direto para o Google.',
        style: TextStyle(color: UT.text2, height: 1.4),
      ),
      const SizedBox(height: UT.s4),
      OutlinedButton.icon(
        icon: const Icon(Icons.open_in_new, size: 18),
        label: const Text('Gerar chave no AI Studio'),
        onPressed: () => launchUrl(Uri.parse(VideoAssistant.keyPage), mode: LaunchMode.externalApplication),
      ),
      const SizedBox(height: UT.s4),
      TextField(
        controller: _keyInput,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        decoration: const InputDecoration(
          labelText: 'Chave da API do Gemini',
          hintText: 'Cole a chave aqui',
          border: OutlineInputBorder(),
        ),
        onSubmitted: (_) => _saveKey(),
      ),
      const SizedBox(height: UT.s3),
      Row(
        children: [
          if (_editingKey && _hasKey == true)
            TextButton(onPressed: () => setState(() => _editingKey = false), child: const Text('Cancelar')),
          const Spacer(),
          FilledButton(
            onPressed: _savingKey ? null : _saveKey,
            child: _savingKey ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Salvar'),
          ),
        ],
      ),
    ],
  );

  Widget _composer() => SafeArea(
    top: false,
    child: Container(
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: UT.line))),
      padding: const EdgeInsets.fromLTRB(UT.s4, UT.s2, UT.s2, UT.s2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: _ask,
              decoration: const InputDecoration(
                hintText: 'Pergunte sobre este vídeo',
                border: InputBorder.none,
                isDense: true,
              ),
            ),
          ),
          if (_busy)
            IconButton(tooltip: 'Parar', icon: const Icon(Icons.stop_circle_outlined), onPressed: _stop)
          else
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _input,
              builder: (_, value, _) => IconButton(
                tooltip: 'Enviar',
                icon: const Icon(Icons.arrow_upward_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: value.text.trim().isEmpty ? UT.surface3 : UT.text,
                  foregroundColor: value.text.trim().isEmpty ? UT.text3 : UT.bg,
                ),
                onPressed: value.text.trim().isEmpty ? null : () => _ask(value.text),
              ),
            ),
        ],
      ),
    ),
  );
}

class _SuggestionTile extends StatelessWidget {
  const _SuggestionTile({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: UT.s2),
    child: Material(
      color: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UT.rLg), side: const BorderSide(color: UT.line)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: UT.s4, vertical: 13),
          child: Row(
            children: [
              Expanded(child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
              const Icon(Icons.north_east_rounded, size: 16, color: UT.text2),
            ],
          ),
        ),
      ),
    ),
  );
}

class _QuestionBubble extends StatelessWidget {
  const _QuestionBubble(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: Container(
      constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(color: UT.surface3, borderRadius: BorderRadius.circular(UT.rLg)),
      child: Text(text),
    ),
  );
}

class _AnswerView extends StatelessWidget {
  const _AnswerView({required this.turn, required this.onRetry, this.onSeek});
  final AskTurn turn;
  final VoidCallback onRetry;
  final void Function(Duration position)? onSeek;

  @override
  Widget build(BuildContext context) {
    if (turn.error != null && turn.answer.isEmpty) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Color(0xFFFF6B6B), size: 20),
          const SizedBox(width: UT.s2),
          Expanded(child: Text(turn.error!, style: const TextStyle(color: UT.text2))),
          TextButton(onPressed: onRetry, child: const Text('Tentar de novo')),
        ],
      );
    }
    if (turn.answer.isEmpty) return const _Thinking();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichAnswer(turn.answer, onSeek: onSeek),
        if (turn.done)
          Row(
            children: [
              IconButton(
                tooltip: 'Copiar',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy_rounded, size: 18, color: UT.text2),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: turn.answer));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Resposta copiada')));
                },
              ),
            ],
          ),
      ],
    );
  }
}

/// Pulsing "Analisando o vídeo…" placeholder (static when motion is reduced).
class _Thinking extends StatefulWidget {
  const _Thinking();
  @override
  State<_Thinking> createState() => _ThinkingState();
}

class _ThinkingState extends State<_Thinking> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat(reverse: true);
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: const [
        Icon(Icons.auto_awesome, size: 16, color: UT.text2),
        SizedBox(width: UT.s2),
        Text('Analisando o vídeo…', style: TextStyle(color: UT.text2)),
      ],
    );
    if (MediaQuery.disableAnimationsOf(context)) return label;
    return FadeTransition(opacity: Tween(begin: 0.4, end: 1.0).animate(_c), child: label);
  }
}

/// Minimal Markdown for answers: headings, bullets, numbered lists, bold,
/// italics, inline code and tappable [m:ss] timestamps.
class RichAnswer extends StatefulWidget {
  const RichAnswer(this.text, {super.key, this.onSeek});
  final String text;
  final void Function(Duration position)? onSeek;
  @override
  State<RichAnswer> createState() => _RichAnswerState();
}

class _RichAnswerState extends State<RichAnswer> {
  final _recognizers = <TapGestureRecognizer>[];
  static final _inline = RegExp(r'\*\*(.+?)\*\*|\*(?!\s)(.+?)\*|`([^`]+)`|\[?\b((?:\d{1,2}:)?\d{1,2}:\d{2})\b\]?');

  void _clear() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  void dispose() {
    _clear();
    super.dispose();
  }

  Duration? _parse(String stamp) {
    final parts = stamp.split(':').map(int.tryParse).toList();
    if (parts.any((p) => p == null)) return null;
    var seconds = 0;
    for (final p in parts) {
      seconds = seconds * 60 + p!;
    }
    return Duration(seconds: seconds);
  }

  List<InlineSpan> _spans(String line, TextStyle base) {
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _inline.allMatches(line)) {
      if (m.start > last) out.add(TextSpan(text: line.substring(last, m.start)));
      if (m.group(1) != null) {
        out.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w700)));
      } else if (m.group(2) != null) {
        out.add(TextSpan(text: m.group(2), style: const TextStyle(fontStyle: FontStyle.italic)));
      } else if (m.group(3) != null) {
        out.add(TextSpan(text: m.group(3), style: const TextStyle(fontFamily: 'monospace', backgroundColor: UT.surface3)));
      } else {
        final stamp = m.group(4)!;
        final at = _parse(stamp);
        if (at != null && widget.onSeek != null) {
          final r = TapGestureRecognizer()
            ..onTap = () {
              HapticFeedback.selectionClick();
              widget.onSeek!(at);
            };
          _recognizers.add(r);
          out.add(
            TextSpan(
              text: stamp,
              recognizer: r,
              style: const TextStyle(color: Color(0xFF3EA6FF), fontWeight: FontWeight.w600),
            ),
          );
        } else {
          out.add(TextSpan(text: m.group(0)));
        }
      }
      last = m.end;
    }
    if (last < line.length) out.add(TextSpan(text: line.substring(last)));
    return out;
  }

  @override
  Widget build(BuildContext context) {
    _clear();
    const base = TextStyle(fontSize: 14.5, height: 1.45, color: UT.text);
    final blocks = <Widget>[];
    for (final raw in widget.text.split('\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        if (blocks.isNotEmpty) blocks.add(const SizedBox(height: UT.s2));
        continue;
      }
      final heading = RegExp(r'^#{1,4}\s+(.*)').firstMatch(line);
      final bullet = RegExp(r'^(\s*)[-*•]\s+(.*)').firstMatch(line);
      final numbered = RegExp(r'^(\s*)(\d+)[.)]\s+(.*)').firstMatch(line);
      if (heading != null) {
        blocks.add(
          Padding(
            padding: const EdgeInsets.only(top: UT.s1, bottom: 2),
            child: Text.rich(TextSpan(style: base.copyWith(fontWeight: FontWeight.w700, fontSize: 15.5), children: _spans(heading.group(1)!.replaceAll('**', ''), base))),
          ),
        );
      } else if (bullet != null || numbered != null) {
        final indent = ((bullet?.group(1) ?? numbered!.group(1)!).length ~/ 2).clamp(0, 3) * 14.0;
        final marker = bullet != null ? '•' : '${numbered!.group(2)}.';
        final content = bullet?.group(2) ?? numbered!.group(3)!;
        blocks.add(
          Padding(
            padding: EdgeInsets.only(left: indent, bottom: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 20, child: Text(marker, style: base.copyWith(color: UT.text2))),
                Expanded(child: Text.rich(TextSpan(style: base, children: _spans(content, base)))),
              ],
            ),
          ),
        );
      } else {
        blocks.add(Text.rich(TextSpan(style: base, children: _spans(line, base))));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks);
  }
}
