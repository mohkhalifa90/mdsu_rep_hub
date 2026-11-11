import 'package:flutter/material.dart';

import '../data/repo.dart';
import '../shared/widgets.dart';

/// Sign in with student / union email: we send a 6-digit code, no password needed.
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _email = TextEditingController();
  final _code = TextEditingController();
  bool _codeSent = false;
  bool _busy = false;

  Future<void> _send() async {
    if (!_email.text.contains('@')) return showSnack(context, 'Enter your student email');
    setState(() => _busy = true);
    final ok = await runAction(context, () => Repo.sendCode(_email.text));
    setState(() {
      _busy = false;
      _codeSent = ok;
    });
  }

  Future<void> _verify() async {
    setState(() => _busy = true);
    await runAction(context, () => Repo.verifyCode(_email.text, _code.text));
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
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Icon(Icons.how_to_vote_outlined, size: 56, color: t.colorScheme.primary),
              const SizedBox(height: 12),
              Text('MDSU Rep Hub', textAlign: TextAlign.center, style: t.textTheme.headlineMedium),
              const SizedBox(height: 4),
              Text('Mälardalen Student Union · Student representatives',
                  textAlign: TextAlign.center, style: t.textTheme.bodySmall),
              const SizedBox(height: 28),
              TextField(
                controller: _email,
                enabled: !_codeSent,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(labelText: 'Student email', hintText: 'name@student.mdu.se'),
                onSubmitted: (_) => _send(),
              ),
              if (_codeSent) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _code,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  decoration: const InputDecoration(labelText: 'Code from the email'),
                  onSubmitted: (_) => _verify(),
                ),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : (_codeSent ? _verify : _send),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(_codeSent ? 'Sign in' : 'Send me a code'),
                ),
              ),
              if (_codeSent)
                TextButton(
                    onPressed: () => setState(() {
                          _codeSent = false;
                          _code.clear();
                        }),
                    child: const Text('Use another email')),
            ]),
          ),
        ),
      ),
    );
  }
}
