import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/repo.dart';
import '../shared/widgets.dart';

/// Sign in or create an account with email + password.
/// New accounts see nothing until the Head of Education activates them.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _password2 = TextEditingController();
  bool _create = false;
  bool _busy = false;
  bool _hide = true;

  Future<void> _submit() async {
    final email = _email.text.trim();
    final pw = _password.text;
    if (!email.contains('@')) return showSnack(context, 'Enter your student email');
    if (pw.length < 8) return showSnack(context, 'The password must be at least 8 characters');
    if (_create) {
      if (_name.text.trim().isEmpty) return showSnack(context, 'Enter your full name');
      if (pw != _password2.text) return showSnack(context, 'The two passwords are not the same');
    }
    setState(() => _busy = true);
    try {
      if (_create) {
        final signedIn = await Repo.signUp(email: email, password: pw, fullName: _name.text.trim());
        if (!signedIn && mounted) {
          showSnack(context, 'Account created. Check your email to confirm it, then sign in.');
          setState(() => _create = false);
        }
      } else {
        await Repo.signIn(email: email, password: pw);
      }
    } catch (e) {
      final msg = errorText(e);
      if (mounted) {
        showSnack(
            context,
            _create && (msg.contains('Database error') || msg.contains('EMAIL_DOMAIN'))
                ? 'Use your student email (…@student.mdu.se). Other email addresses cannot create an account.'
                : (msg.toLowerCase().contains('invalid login')
                    ? 'Wrong email or password. Forgot it? Tap “Forgot password?” below.'
                    : (msg.toLowerCase().contains('already registered')
                        ? 'This email already has an account. Choose “Sign in” instead.'
                        : msg)));
      }
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 380),
            child: AutofillGroup(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Image.asset('assets/logo.png', height: 56),
                const SizedBox(height: 20),
                Text('Rep Hub', textAlign: TextAlign.center, style: t.textTheme.headlineSmall),
                const SizedBox(height: 4),
                Text('Student representatives', textAlign: TextAlign.center, style: t.textTheme.bodySmall),
                const SizedBox(height: 24),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Sign in')),
                    ButtonSegment(value: true, label: Text('Create account')),
                  ],
                  selected: {_create},
                  onSelectionChanged: (s) => setState(() => _create = s.first),
                ),
                const SizedBox(height: 16),
                if (_create) ...[
                  TextField(
                    controller: _name,
                    textCapitalization: TextCapitalization.words,
                    autofillHints: const [AutofillHints.name],
                    decoration: const InputDecoration(labelText: 'Full name'),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'Student email',
                    hintText: 'name@student.mdu.se',
                    suffixIcon: pasteButton(_email),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: _hide,
                  autofillHints: [_create ? AutofillHints.newPassword : AutofillHints.password],
                  decoration: InputDecoration(
                    labelText: 'Password (at least 8 characters)',
                    suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (pasteButton(_password) case final paste?) paste,
                      IconButton(
                        tooltip: _hide ? 'Show password' : 'Hide password',
                        icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hide = !_hide),
                      ),
                    ]),
                  ),
                  onSubmitted: (_) => _create ? null : _submit(),
                ),
                if (_create) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _password2,
                    obscureText: _hide,
                    decoration: InputDecoration(labelText: 'Repeat password', suffixIcon: pasteButton(_password2)),
                    onSubmitted: (_) => _submit(),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _submit,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_create ? 'Create account' : 'Sign in'),
                  ),
                ),
                if (!_create)
                  TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Forgot your password?'),
                        content: const Text(
                            'Contact the Head of Education at utbildning@mdsu.se or on Teams. '
                            'They will give you a temporary password. After you sign in, change it under '
                            'More → My profile → Change my password.'),
                        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
                      ),
                    ),
                    child: const Text('Forgot password?'),
                  ),
                if (_create)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'After you create your account, the Head of Education activates it '
                      'when you are appointed as a student representative.',
                      textAlign: TextAlign.center,
                      style: t.textTheme.bodySmall,
                    ),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}


/// Web version (iPhone Safari): long-press "Paste" does not always appear in Flutter text
/// fields, so the web version shows a paste button. Returns null in the phone/desktop apps.
Widget? pasteButton(TextEditingController controller) {
  if (!kIsWeb) return null;
  return IconButton(
    tooltip: 'Paste',
    icon: const Icon(Icons.content_paste, size: 20),
    onPressed: () async {
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        final text = data?.text?.trim();
        if (text == null || text.isEmpty) return;
        controller.text = text;
        controller.selection = TextSelection.collapsed(offset: text.length);
      } catch (_) {
        // The browser refused clipboard access; nothing to do.
      }
    },
  );
}
