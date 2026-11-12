import 'package:flutter/material.dart';

import '../app/controller.dart';
import '../app/gateway.dart';

const ink = Color(0xFF15251E),
    green = Color(0xFF35D58B),
    paper = Color(0xFFF5F7F5),
    muted = Color(0xFF64736C);
ThemeData mohotewTheme() => ThemeData(
  useMaterial3: true,
  scaffoldBackgroundColor: paper,
  colorScheme: ColorScheme.fromSeed(
    seedColor: green,
    primary: ink,
    secondary: green,
  ),
  fontFamily: 'Roboto',
  appBarTheme: const AppBarTheme(
    backgroundColor: paper,
    foregroundColor: ink,
    centerTitle: false,
    elevation: 0,
  ),
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontSize: 36,
      height: 1.12,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.4,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      height: 1.15,
      fontWeight: FontWeight.w800,
      letterSpacing: -.8,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 21,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      backgroundColor: ink,
      foregroundColor: Colors.white,
      minimumSize: const Size(double.infinity, 56),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
    ),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.all(18),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFDCE4DE)),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(16),
      borderSide: const BorderSide(color: Color(0xFFDCE4DE)),
    ),
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: Color(0xFFD9F7E8),
  ),
);

class Brand extends StatelessWidget {
  const Brand({super.key, this.driver = false});
  final bool driver;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: green,
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Icon(Icons.eco_rounded, color: ink, size: 24),
      ),
      const SizedBox(width: 9),
      Flexible(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            driver ? 'mohotew driver' : 'mohotew',
            style: const TextStyle(
              fontSize: 25,
              fontWeight: FontWeight.w800,
              letterSpacing: -1,
              color: ink,
            ),
          ),
        ),
      ),
    ],
  );
}

class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.color = Colors.white,
    this.padding = 20,
  });
  final Widget child;
  final Color color;
  final double padding;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: EdgeInsets.all(padding),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: const Color(0xFFE4EAE5)),
    ),
    child: child,
  );
}

class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.color = const Color(0xFFD9F7E8)});
  final String text;
  final Color color;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: ink,
      ),
    ),
  );
}

class Notice extends StatelessWidget {
  const Notice(
    this.text, {
    super.key,
    this.action,
    this.label = 'Retry',
    this.icon = Icons.info_outline,
  });
  final String text, label;
  final VoidCallback? action;
  final IconData icon;
  @override
  Widget build(BuildContext context) => Panel(
    color: const Color(0xFFFFF2D5),
    padding: 16,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
        if (action != null) TextButton(onPressed: action, child: Text(label)),
      ],
    ),
  );
}

class ActionButton extends StatefulWidget {
  const ActionButton(
    this.label, {
    super.key,
    required this.onPressed,
    this.icon,
  });
  final String label;
  final Future<void> Function()? onPressed;
  final IconData? icon;
  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool busy = false;
  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: busy || widget.onPressed == null
        ? null
        : () async {
            setState(() => busy = true);
            try {
              await widget.onPressed!();
            } catch (e) {
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(friendlyError(e)),
                    duration: const Duration(seconds: 6),
                  ),
                );
              }
            } finally {
              if (mounted) setState(() => busy = false);
            }
          },
    child: busy
        ? const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon),
                const SizedBox(width: 8),
              ],
              Flexible(child: Text(widget.label, textAlign: TextAlign.center)),
            ],
          ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = 'Confirm',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Go back'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;
void message(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
Future<void> openPage(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
Widget sectionTitle(BuildContext context, String title, [String? subtitle]) =>
    Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        if (subtitle != null) ...[
          const SizedBox(height: 8),
          Text(subtitle, style: const TextStyle(color: muted, height: 1.5)),
        ],
        const SizedBox(height: 24),
      ],
    );
Widget detailRow(String label, String value) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 7),
  child: Row(
    children: [
      Expanded(
        child: Text(label, style: const TextStyle(color: muted)),
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
    ],
  ),
);

class CollectionTile extends StatelessWidget {
  const CollectionTile(this.order, {super.key, required this.onTap});
  final Map<String, dynamic> order;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      child: ListTile(
        contentPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        leading: const CircleAvatar(
          backgroundColor: Color(0xFFD9F7E8),
          child: Icon(Icons.local_shipping_outlined, color: ink),
        ),
        title: Text(
          orderLabel(order),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Text(order['address']?.toString() ?? 'Collection'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    ),
  );
}
