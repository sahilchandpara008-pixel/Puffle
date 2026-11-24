import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/measurement.dart';
import '../theme.dart';

const consentPrefKey = 'terms_accepted_v1';
Future<void> _saveMeasurementChoice(bool allow) => Measurement.instance.saveOnboardingChoice(allow);

Future<void> _askNotifications() async {
  try {
    await Permission.notification.request();
  } catch (_) {/* not available: ignore */}
}

/// Shows "Terms of Service and Privacy Policy" once, on first open. The app is blocked until the
/// user agrees; afterwards the system notification permission prompt is shown.
class ConsentGate extends StatefulWidget {
  const ConsentGate({super.key, required this.child, this.requestNotifications = _askNotifications, this.saveMeasurementChoice = _saveMeasurementChoice});
  final Widget child;
  final Future<void> Function(bool) saveMeasurementChoice;
  final Future<void> Function() requestNotifications;
  @override
  State<ConsentGate> createState() => _ConsentGateState();
}

class _ConsentGateState extends State<ConsentGate> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    final p = await SharedPreferences.getInstance();
    if (!mounted) return;
    if (p.getBool(consentPrefKey) == true) return;
    final agreed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: .75),
      builder: (_) => PopScope(canPop: false, child: ConsentDialog(saveChoice: widget.saveMeasurementChoice)),
    );
    if (agreed == true) {
      await p.setBool(consentPrefKey, true);
      await widget.requestNotifications();

    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class ConsentDialog extends StatefulWidget {
  const ConsentDialog({super.key, required this.saveChoice});
  final Future<void> Function(bool) saveChoice;
  @override
  State<ConsentDialog> createState() => _ConsentDialogState();
}

class _ConsentDialogState extends State<ConsentDialog> {
  bool saving = false;
  String? error;
  Future<void> _accept(bool allow) async {
    setState(() { saving = true; error = null; });
    try {
      await widget.saveChoice(allow);
      final p = await SharedPreferences.getInstance();
      await p.setString('consent_notice_version', '2026-11-single-screen-v1');
      await p.setString('consent_notice_accepted_at', DateTime.now().toUtc().toIso8601String());
      if (mounted) Navigator.pop(context, true);
    } catch (_) {
      if (mounted) setState(() { saving = false; error = 'Could not save your choice on this device. Please try again.'; });
    }
  }
  late final TapGestureRecognizer _privacy;
  late final TapGestureRecognizer _terms;

  Future<void> _open(String path) => launchUrl(Uri.parse('${Config.websiteUrl}$path'), mode: LaunchMode.externalApplication);

  @override
  void initState() {
    super.initState();
    _privacy = TapGestureRecognizer()..onTap = () => _open('/privacy');
    _terms = TapGestureRecognizer()..onTap = () => _open('/terms');
  }

  @override
  void dispose() {
    _privacy.dispose();
    _terms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const link = TextStyle(color: Tokens.accent, decoration: TextDecoration.underline, decorationColor: Tokens.accent);
    return Dialog(
      backgroundColor: Tokens.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: BorderSide(color: Tokens.primary.withValues(alpha: .35))),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.asset('assets/icon.png', width: 46, height: 46, errorBuilder: (_, __, ___) => const SizedBox(width: 46, height: 46))),
          const SizedBox(height: 8),
          const Text('Terms of Service and Privacy Policy', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(style: const TextStyle(color: Tokens.muted, fontSize: 13, height: 1.4), children: [
              const TextSpan(text: 'Welcome to ${Config.appName}. Please review our '),
              TextSpan(text: 'Privacy Policy', style: link, recognizer: _privacy),
              const TextSpan(text: ' and '),
              TextSpan(text: 'Terms & Conditions', style: link, recognizer: _terms),
              const TextSpan(text: '. Either button accepts the terms. Agree and continue also allows optional analytics and ad measurement with Meta and Google. This can include app activity, device and session identifiers, and verified purchases. Meta may also receive hashed account details, IP address, and basic device information. Manage these choices in Account → Measurement preferences.'),
            ]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          if (error != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          SizedBox(width: double.infinity, child: GradientButton(label: saving ? 'Saving…' : 'Agree and continue', onPressed: saving ? null : () => _accept(true))),
          SizedBox(width: double.infinity, child: OutlinedButton(onPressed: saving ? null : () => _accept(false), child: const Text('Continue without optional sharing'))),
        ]),
      ),
    );
  }
}
