import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/auth/login_page.dart';
import 'src/data/models.dart';
import 'src/data/repo.dart';
import 'src/officer/officer_shell.dart';
import 'src/push/push_service.dart';
import 'src/rep/rep_shell.dart';
import 'src/shared/avatars.dart';
import 'src/shared/theme.dart';
import 'src/shared/widgets.dart';

// Pass your project values at build time:
// flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (supabaseUrl.isNotEmpty) {
    await Supabase.initialize(url: supabaseUrl, anonKey: supabaseAnonKey);
  }
  await PushService.instance.init(); // phone notifications (only if Firebase is configured)
  runApp(const RepHubApp());
}

class RepHubApp extends StatelessWidget {
  const RepHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppTheme.instance,
      builder: (context, _) => MaterialApp(
        title: 'MDSU Rep Hub',
        debugShowCheckedModeBanner: false,
        // 24-hour clock everywhere (time pickers and times), as in Sweden
        builder: (context, child) =>
            MediaQuery(data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true), child: child!),
        // MDSU blue by default; everyone can choose light/dark and a colour (Appearance)
        theme: AppTheme.instance.build(Brightness.light),
        darkTheme: AppTheme.instance.build(Brightness.dark),
        themeMode: AppTheme.instance.mode,
        home: supabaseUrl.isEmpty ? const _MissingConfig() : const AuthGate(),
      ),
    );
  }
}

class _MissingConfig extends StatelessWidget {
  const _MissingConfig();
  @override
  Widget build(BuildContext context) => const Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Supabase is not configured.\n\nRun with:\nflutter run --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_ANON_KEY=...',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
}

String? _lookFor; // whose appearance is applied

/// Use the signed-in person's light/dark mode, colour and banner (defaults when signed out).
void _applyLook(Profile? me) {
  if (_lookFor == me?.id) return;
  _lookFor = me?.id;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    AppTheme.instance.applyFrom(me?.uiPrefs, name: me?.fullName ?? '');
    if (me != null) Avatars.instance.load();
  });
}

/// Shows the login page, or the right app for the signed-in user's role.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Repo.sb.auth.onAuthStateChange,
      builder: (context, snap) {
        final session = Repo.sb.auth.currentSession;
        if (session == null) {
          _applyLook(null);
          return const LoginPage();
        }
        return FutureBuilder<Profile>(
          key: ValueKey(session.user.id),
          future: Repo.me(),
          builder: (context, p) {
            if (p.hasError) return ErrorView(error: p.error!, onRetry: () => Repo.sb.auth.signOut());
            if (!p.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
            final me = p.data!;
            _applyLook(me);
            if (!me.active) return _PendingApproval(me: me);
            if (me.mustChangePassword) return _ChooseOwnPassword(me: me);
            return _PushRegistrar(child: me.isOfficer ? OfficerShell(me: me) : RepShell(me: me));
          },
        );
      },
    );
  }
}

/// After a temporary password from the Head of Education: choose your own before going on.
class _ChooseOwnPassword extends StatefulWidget {
  final Profile me;
  const _ChooseOwnPassword({required this.me});
  @override
  State<_ChooseOwnPassword> createState() => _ChooseOwnPasswordState();
}

class _ChooseOwnPasswordState extends State<_ChooseOwnPassword> {
  final _p1 = TextEditingController(), _p2 = TextEditingController();
  String? _error;
  bool _busy = false;

  Future<void> _save() async {
    if (_p1.text.length < 8) return setState(() => _error = 'At least 8 characters');
    if (_p1.text != _p2.text) return setState(() => _error = 'The two passwords are not the same');
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Repo.changeMyPassword(_p1.text);
      if (mounted) {
        Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const AuthGate()));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = errorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Image.asset('assets/logo.png', height: 48),
                const SizedBox(height: 24),
                Text('Welcome, ${widget.me.fullName}!',
                    textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 8),
                const Text('You signed in with a temporary password. Choose your own password to continue.',
                    textAlign: TextAlign.center),
                const SizedBox(height: 16),
                TextField(
                    controller: _p1,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(labelText: 'New password (8+ characters)')),
                const SizedBox(height: 10),
                TextField(
                    controller: _p2,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Repeat new password'),
                    onSubmitted: (_) => _save()),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(_error!, style: TextStyle(color: Colors.red.shade800)),
                  ),
                const SizedBox(height: 16),
                FilledButton(
                    onPressed: _busy ? null : _save,
                    child: const Padding(padding: EdgeInsets.all(12), child: Text('Save and continue'))),
                TextButton(onPressed: Repo.signOut, child: const Text('Sign out')),
              ]),
            ),
          ),
        ),
      );
}

/// New accounts wait until the Head of Education activates them.
class _PendingApproval extends StatelessWidget {
  final Profile me;
  const _PendingApproval({required this.me});
  @override
  Widget build(BuildContext context) => Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Image.asset('assets/logo.png', height: 48),
              const SizedBox(height: 24),
              const Icon(Icons.hourglass_top, size: 40),
              const SizedBox(height: 12),
              Text('Welcome, ${me.fullName}!', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                me.approval == 'rejected'
                    ? 'Your account was not approved. If you think this is a mistake, contact the Head of '
                        'Education at utbildning@mdsu.se.'
                    : 'Your account is waiting for approval by the Head of Education.\n'
                        'You will get access as soon as you are appointed as a student representative.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.pushReplacement(
                    context, MaterialPageRoute(builder: (_) => const AuthGate())),
                child: const Text('Check again'),
              ),
              TextButton(onPressed: Repo.signOut, child: const Text('Sign out')),
            ]),
          ),
        ),
      );
}

/// Saves this phone's push token once the user is signed in and approved.
class _PushRegistrar extends StatefulWidget {
  final Widget child;
  const _PushRegistrar({required this.child});
  @override
  State<_PushRegistrar> createState() => _PushRegistrarState();
}

class _PushRegistrarState extends State<_PushRegistrar> {
  @override
  void initState() {
    super.initState();
    PushService.instance.register();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
