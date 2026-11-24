import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../data/repo.dart';
import 'widgets.dart';

const mdsuBlue = Color(0xFF2F5AAE);
const mdsuLightBlue = Color(0xFF21BBEF);

/// The colours to choose from. MDSU blue is the default.
const accents = <String, (String, Color)>{
  'blue': ('MDSU blue', mdsuBlue),
  'sky': ('Sky', Color(0xFF0B8BC4)),
  'teal': ('Teal', Color(0xFF00897B)),
  'green': ('Forest', Color(0xFF2E7D32)),
  'purple': ('Purple', Color(0xFF6A4BC4)),
  'rose': ('Rose', Color(0xFFC2185B)),
  'amber': ('Sand', Color(0xFFB7791F)),
};

/// Banners drawn by the app (they take the chosen colour). Pictures can be added as assets later.
const banners = <String, String>{
  'waves': 'Waves',
  'aurora': 'Aurora',
  'dusk': 'Dusk',
  'grid': 'Lines',
  'none': 'No banner',
};

/// Light/dark mode, colour and banner for the signed-in person. Saved on their profile.
class AppTheme extends ChangeNotifier {
  AppTheme._();
  static final instance = AppTheme._();

  ThemeMode mode = ThemeMode.system;
  String accent = 'blue';
  String banner = 'waves';
  String? bannerUrl; // own picture
  bool onboarded = false; // has seen the welcome tour

  Color get seed => accents[accent]?.$2 ?? mdsuBlue;

  void applyFrom(Map<String, dynamic>? prefs) {
    final p = prefs ?? const {};
    mode = switch (p['mode']) { 'light' => ThemeMode.light, 'dark' => ThemeMode.dark, _ => ThemeMode.system };
    accent = accents.containsKey(p['accent']) ? p['accent'] as String : 'blue';
    banner = (p['banner'] as String?) ?? 'waves';
    bannerUrl = p['banner_url'] as String?;
    onboarded = p['onboarded'] == true;
    if (banner == 'custom' && bannerUrl == null) banner = 'waves';
    notifyListeners();
  }

  /// Back to the defaults (e.g. after signing out)
  void reset() => applyFrom(null);

  Map<String, dynamic> toJson() => {
        'mode': switch (mode) { ThemeMode.light => 'light', ThemeMode.dark => 'dark', _ => 'system' },
        'accent': accent,
        'banner': banner,
        if (bannerUrl != null) 'banner_url': bannerUrl,
        if (onboarded) 'onboarded': true,
      };

  Future<void> save() async {
    notifyListeners();
    try {
      await Repo.saveMyPrefs(toJson());
    } catch (_) {
      // the look still changes on this device; it is saved next time
    }
  }

  ThemeData build(Brightness b) {
    final dark = b == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: b,
      primary: dark ? null : seed,
      secondary: accent == 'blue' ? mdsuLightBlue : null,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: dark ? const Color(0xFF111318) : const Color(0xFFF6F7FB),
      appBarTheme: AppBarTheme(
        backgroundColor: dark ? const Color(0xFF181B21) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        color: dark ? const Color(0xFF1C2027) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: dark ? const Color(0xFF2A2F38) : const Color(0xFFE6E8EF)),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: dark ? const Color(0xFF181B21) : Colors.white,
        indicatorColor: scheme.primaryContainer,
      ),
      inputDecorationTheme: const InputDecorationTheme(border: OutlineInputBorder(), isDense: true),
    );
  }
}

/// A soft colour for status backgrounds that works in light and dark mode.
Color softBg(BuildContext context, Color c) =>
    Theme.of(context).brightness == Brightness.dark ? c.withValues(alpha: 0.18) : c.withValues(alpha: 0.10);

// ---------------------------------------------------------------------------
// Banner
// ---------------------------------------------------------------------------

/// The header picture with a greeting on top (Today page and the reps' Home).
class BannerHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final double height;
  const BannerHeader({super.key, required this.title, required this.subtitle, this.height = 150});

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: AppTheme.instance, builder: (context, _) => _build(context));

  Widget _build(BuildContext context) {
    final th = AppTheme.instance;
    final t = Theme.of(context);
    if (th.banner == 'none') {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: t.textTheme.headlineSmall),
        const SizedBox(height: 2),
        Text(subtitle),
      ]);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: SizedBox(
        height: height,
        child: Stack(fit: StackFit.expand, children: [
          _BannerArt(style: th.banner, url: th.bannerUrl, color: t.colorScheme.primary),
          // keeps the text readable on any picture
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0x99000000), Color(0x22000000)],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: Column(mainAxisAlignment: MainAxisAlignment.end, crossAxisAlignment: CrossAxisAlignment.start, children: [
              TweenAnimationBuilder<double>(
                tween: Tween(begin: 0, end: 1),
                duration: const Duration(milliseconds: 500),
                curve: Curves.easeOut,
                builder: (context, v, child) =>
                    Opacity(opacity: v, child: Transform.translate(offset: Offset(0, 8 * (1 - v)), child: child)),
                child: Text(title,
                    style: t.textTheme.headlineSmall?.copyWith(color: Colors.white, fontWeight: FontWeight.w700)),
              ),
              const SizedBox(height: 4),
              Text(subtitle, style: t.textTheme.bodyMedium?.copyWith(color: Colors.white.withValues(alpha: 0.9))),
            ]),
          ),
        ]),
      ),
    );
  }
}

class _BannerArt extends StatelessWidget {
  final String style;
  final String? url;
  final Color color;
  const _BannerArt({required this.style, required this.url, required this.color});

  @override
  Widget build(BuildContext context) {
    if (style == 'custom' && url != null) {
      return Image.network(url!, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => CustomPaint(painter: _BannerPainter('waves', color)));
    }
    return CustomPaint(painter: _BannerPainter(style, color));
  }
}

class _BannerPainter extends CustomPainter {
  final String style;
  final Color color;
  _BannerPainter(this.style, this.color);

  Color _shift(double l, [double s = 0]) {
    final h = HSLColor.fromColor(color);
    return h.withLightness((h.lightness + l).clamp(0.05, 0.95)).withSaturation((h.saturation + s).clamp(0, 1)).toColor();
  }

  @override
  void paint(Canvas canvas, Size size) {
    final r = Offset.zero & size;
    switch (style) {
      case 'aurora':
        canvas.drawRect(r, Paint()..color = _shift(-0.25));
        for (final (dx, dy, rad, l, hue) in const [
          (0.15, 0.2, 0.55, 0.15, -40.0),
          (0.6, 0.9, 0.6, 0.05, 30.0),
          (0.95, 0.1, 0.45, 0.2, 70.0),
        ]) {
          final h = HSLColor.fromColor(_shift(l)).withHue((HSLColor.fromColor(color).hue + hue) % 360);
          canvas.drawCircle(
            Offset(size.width * dx, size.height * dy),
            size.width * rad,
            Paint()
              ..shader = RadialGradient(colors: [h.toColor().withValues(alpha: 0.75), h.toColor().withValues(alpha: 0)])
                  .createShader(Rect.fromCircle(center: Offset(size.width * dx, size.height * dy), radius: size.width * rad)),
          );
        }
      case 'dusk':
        canvas.drawRect(
            r,
            Paint()
              ..shader = LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [_shift(-0.3), _shift(0.05), const Color(0xFFF2A65A)],
                stops: const [0, 0.65, 1],
              ).createShader(r));
        // a skyline of simple buildings
        final p = Paint()..color = _shift(-0.38);
        final rnd = math.Random(7);
        var x = 0.0;
        while (x < size.width) {
          final w = 24 + rnd.nextDouble() * 50;
          final h = size.height * (0.18 + rnd.nextDouble() * 0.35);
          canvas.drawRect(Rect.fromLTWH(x, size.height - h, w - 4, h), p);
          x += w;
        }
      case 'grid':
        canvas.drawRect(
            r,
            Paint()
              ..shader = LinearGradient(colors: [_shift(-0.2), _shift(0.05)]).createShader(r));
        final line = Paint()
          ..color = Colors.white.withValues(alpha: 0.10)
          ..strokeWidth = 1;
        for (var i = -size.height; i < size.width; i += 22) {
          canvas.drawLine(Offset(i, size.height), Offset(i + size.height, 0), line);
        }
      default: // waves
        canvas.drawRect(
            r,
            Paint()
              ..shader = LinearGradient(colors: [_shift(-0.15), _shift(0.1, 0.1)]).createShader(r));
        for (var i = 0; i < 3; i++) {
          final path = Path()..moveTo(0, size.height * (0.55 + i * 0.12));
          for (var x = 0.0; x <= size.width; x += 8) {
            path.lineTo(x, size.height * (0.55 + i * 0.12) + math.sin(x / size.width * math.pi * 2 + i) * 14);
          }
          path
            ..lineTo(size.width, size.height)
            ..lineTo(0, size.height)
            ..close();
          canvas.drawPath(path, Paint()..color = Colors.white.withValues(alpha: 0.08 + i * 0.04));
        }
    }
  }

  @override
  bool shouldRepaint(_BannerPainter old) => old.style != style || old.color != color;
}

// ---------------------------------------------------------------------------
// Appearance settings
// ---------------------------------------------------------------------------

/// Light/dark, colour and banner. Opens as a bottom sheet from the menu or settings.
Future<void> showAppearanceSheet(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => const _AppearanceSheet(),
    );

class _AppearanceSheet extends StatefulWidget {
  const _AppearanceSheet();
  @override
  State<_AppearanceSheet> createState() => _AppearanceSheetState();
}

class _AppearanceSheetState extends State<_AppearanceSheet> {
  final th = AppTheme.instance;
  bool _uploading = false;

  Future<void> _upload() async {
    final r = await FilePicker.platform.pickFiles(type: FileType.image, withData: true);
    final f = r?.files.single;
    if (f?.bytes == null) return;
    if (f!.size > 5 * 1024 * 1024) {
      if (mounted) showSnack(context, 'Pictures up to 5 MB');
      return;
    }
    setState(() => _uploading = true);
    try {
      th.bannerUrl = await Repo.uploadBanner(f.name, f.bytes!);
      th.banner = 'custom';
      await th.save();
    } catch (e) {
      if (mounted) showSnack(context, errorText(e));
    }
    if (mounted) setState(() => _uploading = false);
  }

  void _set(VoidCallback change) {
    setState(change);
    th.save();
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Appearance', style: t.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text('Saved to your account – the same on your phone and computer.', style: t.textTheme.bodySmall),
          const SizedBox(height: 16),
          Text('Mode', style: t.textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.light, icon: Icon(Icons.light_mode_outlined), label: Text('Light')),
              ButtonSegment(value: ThemeMode.dark, icon: Icon(Icons.dark_mode_outlined), label: Text('Dark')),
              ButtonSegment(value: ThemeMode.system, icon: Icon(Icons.brightness_auto_outlined), label: Text('Auto')),
            ],
            selected: {th.mode},
            onSelectionChanged: (s) => _set(() => th.mode = s.first),
          ),
          const SizedBox(height: 20),
          Text('Colour', style: t.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final e in accents.entries)
              Tooltip(
                message: e.value.$1,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _set(() => th.accent = e.key),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: e.value.$2,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: th.accent == e.key ? t.colorScheme.onSurface : Colors.transparent, width: 3),
                    ),
                    child: th.accent == e.key ? const Icon(Icons.check, color: Colors.white) : null,
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 20),
          Text('Banner on the start page', style: t.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final e in banners.entries)
              _BannerChoice(
                selected: th.banner == e.key,
                label: e.value,
                onTap: () => _set(() => th.banner = e.key),
                child: e.key == 'none'
                    ? const Center(child: Icon(Icons.hide_image_outlined))
                    : CustomPaint(painter: _BannerPainter(e.key, t.colorScheme.primary)),
              ),
            if (th.bannerUrl != null)
              _BannerChoice(
                selected: th.banner == 'custom',
                label: 'My picture',
                onTap: () => _set(() => th.banner = 'custom'),
                child: Image.network(th.bannerUrl!, fit: BoxFit.cover),
              ),
            _BannerChoice(
              selected: false,
              label: _uploading ? 'Uploading…' : 'Upload picture',
              onTap: _uploading ? () {} : _upload,
              child: Center(
                  child: _uploading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add_photo_alternate_outlined)),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _BannerChoice extends StatelessWidget {
  final bool selected;
  final String label;
  final VoidCallback onTap;
  final Widget child;
  const _BannerChoice({required this.selected, required this.label, required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 120,
          height: 64,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: t.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: selected ? t.colorScheme.primary : Colors.transparent, width: 3),
          ),
          child: child,
        ),
        const SizedBox(height: 4),
        Text(label, style: t.textTheme.bodySmall),
      ]),
    );
  }
}
