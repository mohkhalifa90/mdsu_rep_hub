import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'src/auth/login_page.dart';
import 'src/data/models.dart';
import 'src/data/repo.dart';
import 'src/officer/officer_shell.dart';
import 'src/push/push_service.dart';
import 'src/rep/rep_shell.dart';
import 'src/shared/widgets.dart';

// Pass your project values at build time:
// flutter run --dart-define=SUPABASE_URL=https://xxxx.supabase.co --dart-define=SUPABASE_ANON_KEY=eyJ...
const supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const mdsuBlue = Color(0xFF2F5AAE);
const mdsuLightBlue = Color(0xFF21BBEF);
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
    return MaterialApp(
      title: 'MDSU Rep Hub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        // MDSU colours: blue from mdsu.se, light blue from the logo
        colorScheme: ColorScheme.fromSeed(
          seedColor: mdsuBlue,
          primary: mdsuBlue,
          secondary: mdsuLightBlue,
        ),
        scaffoldBackgroundColor: const Color(0xFFF7F8FB),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.white, surfaceTintColor: Colors.white),
        inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
      ),
      home: supabaseUrl.isEmpty ? const _MissingConfig() : const AuthGate(),
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

/// Shows the login page, or the right app for the signed-in user's role.
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<AuthState>(
      stream: Repo.sb.auth.onAuthStateChange,
      builder: (context, snap) {
        final session = Repo.sb.auth.currentSession;
        if (session == null) return const LoginPage();
        return FutureBuilder<Profile>(
          key: ValueKey(session.user.id),
          future: Repo.me(),
          builder: (context, p) {
            if (p.hasError) return ErrorView(error: p.error!, onRetry: () => Repo.sb.auth.signOut());
            if (!p.hasData) return const Scaffold(body: Center(child: CircularProgressIndicator()));
            final me = p.data!;
            if (!me.active) return _PendingApproval(me: me);
            return _PushRegistrar(child: me.isOfficer ? OfficerShell(me: me) : RepShell(me: me));
          },
        );
      },
    );
  }
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
              const Text(
                'Your account is waiting for approval by the Head of Education.\n'
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
