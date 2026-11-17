import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../shared/widgets.dart';
import 'push_service.dart';

/// Web version only: lets the user turn on notifications on this device
/// (iPhone requires a tap, and the app must be opened from the Home Screen).
class WebPushCard extends StatefulWidget {
  const WebPushCard({super.key});
  @override
  State<WebPushCard> createState() => _WebPushCardState();
}

class _WebPushCardState extends State<WebPushCard> {
  WebPushState? _state;
  bool _busy = false;
  bool _hidden = false;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      PushService.instance.webState().then((s) {
        if (mounted) setState(() => _state = s);
      });
    }
  }

  Future<void> _enable() async {
    setState(() => _busy = true);
    try {
      final s = await PushService.instance.enableWeb();
      if (!mounted) return;
      setState(() => _state = s);
      if (s == WebPushState.on) showSnack(context, 'Notifications are on ✓');
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _card(IconData icon, String title, String text, {Widget? action, bool closable = true}) {
    final t = Theme.of(context);
    return Card(
      color: t.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 2), child: Icon(icon)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: t.textTheme.titleSmall),
              const SizedBox(height: 4),
              Text(text, style: t.textTheme.bodySmall),
              if (action != null) ...[const SizedBox(height: 8), action],
            ]),
          ),
          if (closable)
            IconButton(
              tooltip: 'Hide',
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => setState(() => _hidden = true),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb || _hidden) return const SizedBox.shrink();
    final iphone = defaultTargetPlatform == TargetPlatform.iOS;
    switch (_state) {
      case WebPushState.ask:
        return _card(
          Icons.notifications_active_outlined,
          'Get notifications on this ${iphone ? 'iPhone' : 'device'}',
          'Reminders, announcements and replies – even when the app is closed.',
          action: FilledButton(
            onPressed: _busy ? null : _enable,
            child: Text(_busy ? 'Turning on…' : 'Turn on notifications'),
          ),
        );
      case WebPushState.unsupported:
        if (!iphone) return const SizedBox.shrink();
        return _card(
          Icons.add_to_home_screen,
          'Notifications on iPhone',
          'Add this app to your Home Screen (Share → Add to Home Screen) and open it from the icon. '
              'Then you can turn on notifications here. Needs iOS 16.4 or newer.',
        );
      case WebPushState.blocked:
        return _card(
          Icons.notifications_off_outlined,
          'Notifications are blocked',
          iphone
              ? 'Turn them on in the iPhone Settings → Notifications → MDSU Reps.'
              : 'Allow notifications for this site in your browser settings.',
        );
      default:
        return const SizedBox.shrink();
    }
  }
}
