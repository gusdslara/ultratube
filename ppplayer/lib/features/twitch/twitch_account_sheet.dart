import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/ultratube_theme.dart';
import '../../core/twitch/twitch_account.dart';
import '../../core/twitch/twitch_providers.dart';
import '../ultratube/yt_widgets.dart' show Avatar;

/// Twitch account: sign in with a code, or manage the signed-in account.
Future<void> showTwitchAccountSheet(BuildContext context) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  backgroundColor: UT.surface1,
  builder: (_) => const SafeArea(child: _AccountSheet()),
);

class _AccountSheet extends ConsumerStatefulWidget {
  const _AccountSheet();
  @override
  ConsumerState<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends ConsumerState<_AccountSheet> {
  TwitchSignIn? _signIn;
  bool _busy = false;
  bool _closed = false;
  String? _error;

  @override
  void dispose() {
    _closed = true; // stops the pending sign-in poll
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _start() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final account = ref.read(twitchAccountProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final signIn = await account.begin();
      if (!mounted) return;
      setState(() {
        _signIn = signIn;
        _busy = false;
      });
      final message = await account.complete(signIn, cancelled: () => _closed || _signIn != signIn);
      if (message == null) return;
      ref.invalidate(twitchFollowedProvider);
      messenger.showSnackBar(SnackBar(content: Text(message)));
      if (mounted) navigator.pop();
    } catch (error) {
      if (mounted) {
        setState(() {
          _signIn = null;
          _busy = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _open(TwitchSignIn signIn) async {
    await Clipboard.setData(ClipboardData(text: signIn.code));
    final ok = await launchUrl(Uri.parse(signIn.url), mode: LaunchMode.externalApplication);
    if (!ok) _toast('Abra twitch.tv/activate no navegador e digite o código.');
  }

  Future<void> _sync() async {
    setState(() => _busy = true);
    try {
      final added = await ref.read(twitchAccountProvider.notifier).syncFollows();
      ref.invalidate(twitchFollowedProvider);
      _toast(added == 0 ? 'Seus canais já estão atualizados.' : '$added ${added == 1 ? 'canal importado' : 'canais importados'}.');
    } catch (_) {
      _toast('Não foi possível buscar seus canais agora.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(twitchAccountProvider);
    final signIn = _signIn;
    return Padding(
      padding: const EdgeInsets.fromLTRB(UT.s5, 0, UT.s5, UT.s5),
      child: AnimatedSize(
        duration: UT.motion,
        curve: UT.curve,
        alignment: Alignment.topCenter,
        child: account != null
            ? _signedIn(account)
            : signIn != null
            ? _waiting(signIn)
            : _intro(),
      ),
    );
  }

  Widget _intro() => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Entrar na Twitch', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: UT.s2),
      const Text(
        'Traga para "Seguindo" os canais que você já segue na Twitch. Você confirma o acesso com um código no site da Twitch; sua senha nunca passa por este app.',
        style: TextStyle(color: UT.text2, height: 1.4),
      ),
      if (_error != null) ...[
        const SizedBox(height: UT.s3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.error_outline, size: 18, color: UT.red),
            const SizedBox(width: UT.s2),
            Expanded(child: Text(_error!, style: const TextStyle(color: UT.text))),
          ],
        ),
      ],
      const SizedBox(height: UT.s5),
      FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: UT.twitch, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
        onPressed: _busy ? null : _start,
        icon: _busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.login_rounded),
        label: Text(_busy ? 'Gerando código…' : (_error != null ? 'Gerar novo código' : 'Gerar código de acesso')),
      ),
    ],
  );

  Widget _waiting(TwitchSignIn signIn) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Confirme na Twitch', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
      const SizedBox(height: UT.s2),
      const Text(
        'Abra twitch.tv/activate, entre na sua conta e confirme este código:',
        style: TextStyle(color: UT.text2, height: 1.4),
      ),
      const SizedBox(height: UT.s4),
      Semantics(
        label: 'Código ${signIn.code.split('').join(' ')}. Toque para copiar.',
        button: true,
        child: Material(
          color: UT.surface2,
          borderRadius: BorderRadius.circular(UT.rMd),
          child: InkWell(
            borderRadius: BorderRadius.circular(UT.rMd),
            onTap: () {
              Clipboard.setData(ClipboardData(text: signIn.code));
              _toast('Código copiado');
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UT.s4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  ExcludeSemantics(
                    child: Text(
                      signIn.code,
                      style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800, letterSpacing: 6, fontFeatures: [FontFeature.tabularFigures()]),
                    ),
                  ),
                  const SizedBox(width: UT.s3),
                  const Icon(Icons.copy_rounded, size: 20, color: UT.text2),
                ],
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: UT.s4),
      FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: UT.twitch, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
        onPressed: () => _open(signIn),
        icon: const Icon(Icons.open_in_new_rounded),
        label: const Text('Abrir twitch.tv/activate'),
      ),
      const SizedBox(height: UT.s4),
      const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2, color: UT.twitch)),
          SizedBox(width: UT.s3),
          Text('Aguardando a confirmação…', style: TextStyle(color: UT.text2)),
        ],
      ),
      const SizedBox(height: UT.s2),
      TextButton(
        onPressed: () => setState(() => _signIn = null),
        child: const Text('Cancelar'),
      ),
    ],
  );

  Widget _signedIn(TwitchAccountInfo account) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Avatar(account.avatar, size: 52),
          const SizedBox(width: UT.s4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(account.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                Text('twitch.tv/${account.login}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: UT.text2)),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: UT.s5),
      FilledButton.icon(
        style: FilledButton.styleFrom(backgroundColor: UT.twitch, foregroundColor: Colors.white, minimumSize: const Size.fromHeight(48)),
        onPressed: _busy ? null : _sync,
        icon: _busy
            ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.sync_rounded),
        label: Text(_busy ? 'Buscando canais…' : 'Atualizar canais seguidos'),
      ),
      const SizedBox(height: UT.s2),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: UT.text, side: const BorderSide(color: UT.line), minimumSize: const Size.fromHeight(48)),
        onPressed: _busy
            ? null
            : () async {
                final navigator = Navigator.of(context);
                await ref.read(twitchAccountProvider.notifier).signOut();
                _toast('Você saiu da Twitch. Os canais seguidos continuam neste aparelho.');
                navigator.pop();
              },
        icon: const Icon(Icons.logout_rounded),
        label: const Text('Sair da conta'),
      ),
    ],
  );
}
