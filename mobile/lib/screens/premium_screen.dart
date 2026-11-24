import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config.dart';
import '../payments/upi.dart';
import '../services/app_scope.dart';
import '../services/app_state.dart';
import '../services/measurement.dart';
import '../theme.dart';
import 'login_sheet.dart';
import 'payment_status_screen.dart';
import 'plans_page.dart';

/// Premium entry. Which of the four states shows is decided by the SERVER values in my_status.
class PremiumScreen extends StatelessWidget {
  const PremiumScreen({super.key, this.plansLoader, this.actions = const [], this.embedded = false});

  /// Extra app-bar buttons (Profile uses this for the Account button).
  final List<Widget> actions;

  /// Lets tests replace the server call that lists plans.
  final PlansLoader? plansLoader;

  /// Inside the Profile tab: no app bar, the plans page draws its own "Go Premium" header.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Premium'), actions: actions),
      body: ListenableBuilder(
        listenable: app,
        builder: (context, _) {
          final s = app.status;
          // 1) Free mode, or Play build: no prices anywhere.
          if (Config.playStore || s.freeMode) return const FreeAccountCard();
          // 2) Plans hidden for this user.
          if (!s.plansVisible) {
            return s.isPremium ? const _ActivePlan() : const Center(child: Text('Premium is not available right now.'));
          }
          // 3) Paid mode, plans visible: native plans page ("Go Premium").
          final page = PlansPage(
            plansLoader: plansLoader,
            freeIds: app.freePlanIds,
            paused: !s.paymentsAvailable,
            showHeader: embedded,
            actions: actions,
            onBuy: (id) => startPurchase(context, id),
          );
          return Column(children: [
            if (s.isPremium) const _ActivePlan(),
            Expanded(child: page),
          ]);
        },
      ),
    );
  }
}

class _ActivePlan extends StatelessWidget {
  const _ActivePlan();
  @override
  Widget build(BuildContext context) {
    final s = AppScope.of(context).status;
    final d = s.planEndsAt;
    final date = d == null ? '' : ' until ${d.day}/${d.month}/${d.year}';
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Card(child: ListTile(
        leading: const Icon(Icons.workspace_premium, color: Tokens.gold),
        title: Text('${s.planName ?? 'Premium'} active$date'),
        trailing: TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PaymentHistoryScreen())), child: const Text('History')),
      )),
    );
  }
}

class FreeAccountCard extends StatelessWidget {
  const FreeAccountCard({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final s = app.status;
    final gb = (s.quotaBytes / (1 << 30)).toStringAsFixed(0);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Free account', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 8),
        if (s.isGuest) ...[
          const Text('Log in to get 15 GB free cloud storage'),
          const SizedBox(height: 12),
          GradientButton(label: 'Log in', onPressed: () => requireAccount(context)),
        ] else ...[
          Text('$gb GB cloud storage'),
          const SizedBox(height: 8),
          _access(context, app),
        ],
      ]))),
    ]);
  }

  Widget _access(BuildContext context, AppState app) {
    final s = app.status;
    if (s.hasAdsAccess || s.source == 'ads') return const Text('Full access: active', style: TextStyle(color: Tokens.success));
    switch (s.accessStatus) {
      case 'pending':
        return const Text('Full access request pending', style: TextStyle(color: Tokens.warning));
      case 'approved':
        return const Text('Full access approved', style: TextStyle(color: Tokens.success));
      case 'rejected':
        return const Text('Full access request was not approved', style: TextStyle(color: Tokens.muted));
      default:
        return GradientButton(label: 'Request full access', onPressed: () async {
          try { await sb.rpc('request_full_access'); await app.refresh(); } catch (_) {}
        });
    }
  }
}

class PlansWebView extends StatefulWidget {
  const PlansWebView({super.key, required this.uri});
  final Uri uri;
  @override
  State<PlansWebView> createState() => _PlansWebViewState();
}

class _PlansWebViewState extends State<PlansWebView> {
  late final WebViewController _c;
  int _progress = 0;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _c = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Tokens.background)
      ..addJavaScriptChannel('${Config.appName}App', onMessageReceived: (m) => _onMessage(m.message))
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (r) => isAllowedWebUrl(r.url) ? NavigationDecision.navigate : NavigationDecision.prevent,
        onProgress: (p) => setState(() => _progress = p),
        onPageStarted: (_) => setState(() => _error = false),
        onWebResourceError: (e) { if (e.isForMainFrame ?? true) setState(() => _error = true); },
      ))
      ..loadRequest(widget.uri);
  }

  @override
  void didUpdateWidget(PlansWebView old) {
    super.didUpdateWidget(old);
    if (old.uri != widget.uri) _c.loadRequest(widget.uri);
  }

  Future<void> _onMessage(String raw) async {
    final msg = BuyMessage.tryParse(raw);
    if (msg == null) return;
    await startPurchase(context, msg.planId);
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        if (_error)
          Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text("Couldn't load plans"),
            TextButton(onPressed: () { setState(() => _error = false); _c.loadRequest(widget.uri); }, child: const Text('Retry')),
          ]))
        else
          WebViewWidget(controller: _c),
        if (_progress < 100 && !_error) LinearProgressIndicator(value: _progress / 100),
      ]);
}

/// Buy flow: free plan -> claim; otherwise native UPI checkout. All decisions are the server's.
Future<void> startPurchase(BuildContext context, String planId) async {
  final app = AppScope.of(context);
  Measurement.instance.track('PlanViewed',{'screen':'Premium'});
  final messenger = ScaffoldMessenger.of(context);
  final nav = Navigator.of(context);

  // Guests can buy too (they get a guest session and can add an email later to keep the plan).
  if (!await app.ensureSession()) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not start a guest session. Please log in to continue.')));
    if (context.mounted) await requireAccount(context);
    return;
  }
  if (!context.mounted) return;
  try {
    final plan = await sb.from('plans')
        .select('name,price_inr,duration_days,duration_hours,perks')
        .eq('id', planId).eq('active', true).maybeSingle();
    if (plan == null) {
      messenger.showSnackBar(const SnackBar(content: Text('This plan is no longer available.')));
      return;
    }
    if (!context.mounted) return;
    if (app.freePlanIds.contains(planId)) {
      final r = await app.claimFree(planId);
      final end = r['ends_at'] ?? r['plan_ends_at'];
      messenger.showSnackBar(SnackBar(content: Text('Plan activated${end != null ? ' until ${DateTime.parse(end as String).toLocal().toString().split(' ').first}' : ''}')));
      return;
    }
    final shown = plan['price_inr'] as num;
    final agreed = await showDialog<bool>(
      context: context,
      builder: (_) => PaymentConfirmationDialog(plan: plan),
    );
    if (agreed != true || !context.mounted) return;
    final order = await app.createOrder(planId);
    final amount = order['amount_inr'] as num;
    if (amount != shown && context.mounted) {
      await showDialog<void>(context: context, builder: (c) => AlertDialog(
        title: Text('Price updated to ₹$amount'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Continue'))],
      ));
    }
    final uri = buildUpiUri(
      upiId: order['upi_id'] as String,
      payee: order['payee_name'] as String,
      reference: order['reference'] as String,
      amountInr: amount,
    );
    String? raw;
    try {
      raw = await app.launchUpi(uri);
    } on PlatformException catch (e) {
      if (e.code == 'NO_APP' && context.mounted) {
        await _manualSheet(context, order);
        return;
      }
      raw = null;
    }
    // Save locally FIRST, then report.
    await app.saveAndReport(order['order_id'] as String, raw ?? 'NO_RESPONSE');
    nav.push(MaterialPageRoute(builder: (_) => PaymentStatusScreen(orderId: order['order_id'] as String)));
  } on PostgrestException catch (e) {
    messenger.showSnackBar(SnackBar(content: Text(e.message)));
  } catch (_) {
    messenger.showSnackBar(const SnackBar(content: Text('Could not start payment. Please try again.')));
  }
}

class PaymentConfirmationDialog extends StatelessWidget {
  const PaymentConfirmationDialog({super.key, required this.plan});
  final Map<String, dynamic> plan;

  @override
  Widget build(BuildContext context) {
    final amount = '₹${plan['price_inr']}';
    final days = (plan['duration_days'] as num).toInt();
    final hours = (plan['duration_hours'] as num?)?.toInt() ?? 0;
    final perks = (plan['perks'] as List? ?? const []).whereType<String>()
        .where((perk) => perk.trim().isNotEmpty).toList();
    const secondary = TextStyle(color: Tokens.muted, fontSize: 13, height: 1.35);
    return AlertDialog(
      scrollable: true,
      backgroundColor: Tokens.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: Tokens.border),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      titlePadding: const EdgeInsets.fromLTRB(14, 4, 6, 0),
      title: Row(children: [
        const Icon(Icons.workspace_premium, color: Tokens.accent, size: 24),
        const SizedBox(width: 8),
        Expanded(child: Text('${plan['name']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
        IconButton(
          tooltip: 'Close payment confirmation',
          onPressed: () => Navigator.pop(context, false),
          icon: const Icon(Icons.close_rounded),
        ),
      ]),
      contentPadding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
      content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(alignment: WrapAlignment.spaceBetween, spacing: 10, runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('${durationLabel(days, hours)} of Premium', style: secondary),
            Text(amount, style: const TextStyle(color: Tokens.accent, fontSize: 22, fontWeight: FontWeight.w700)),
          ]),
        if (perks.isNotEmpty) ...[
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: Tokens.background, borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Tokens.border)),
            child: Column(children: [
              for (final perk in perks)
                Padding(padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Icon(Icons.check_circle, size: 16, color: Tokens.success),
                    const SizedBox(width: 8),
                    Expanded(child: Text(perk, style: const TextStyle(fontSize: 13))),
                  ])),
            ]),
          ),
        ],
        const SizedBox(height: 7),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(color: Tokens.primary.withValues(alpha: .15), borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Tokens.primary)),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Icon(Icons.lock_outline, color: Tokens.accent, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text("You'll pay $amount for Puffle Premium in your UPI app. One-time payment · No auto-renewal.",
              style: const TextStyle(fontSize: 13, height: 1.35))),
          ]),
        ),
        const SizedBox(height: 7),
        const Text("Debited but still waiting? Check your status or email support with the order reference before retrying.", style: secondary),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('By paying you accept the', style: secondary),
          TextButton(onPressed: () => launchUrl(Uri.parse('${Config.websiteUrl}/terms'), mode: LaunchMode.externalApplication),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 5)),
            child: const Text('Terms', style: TextStyle(color: Tokens.accent, fontSize: 12))),
          const Text('and', style: secondary),
          TextButton(onPressed: () => launchUrl(Uri.parse('${Config.websiteUrl}/refund'), mode: LaunchMode.externalApplication),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 5)),
            child: const Text('Refund Policy', style: TextStyle(color: Tokens.accent, fontSize: 12))),
          TextButton(onPressed: () => launchUrl(Uri(scheme: 'mailto', path: Config.supportEmail)),
            style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 5)),
            child: const Text('Email support', style: TextStyle(color: Tokens.accent, fontSize: 12))),
        ]),

      ]),
      actionsPadding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
      actions: [
        SizedBox(width: double.infinity, child: GradientButton(
          label: 'Pay $amount securely',
          onPressed: () => Navigator.pop(context, true),
        )),
      ],
    );
  }
}

Future<void> _manualSheet(BuildContext context, Map<String, dynamic> o) => showModalBottomSheet<void>(
      context: context,
      backgroundColor: Tokens.surface,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('No UPI app found. Pay manually:', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          for (final e in {'UPI ID': o['upi_id'], 'Amount': '${o['amount_inr']}', 'Reference': o['reference']}.entries)
            ListTile(
              dense: true,
              title: Text(e.key, style: const TextStyle(color: Tokens.muted)),
              subtitle: Text('${e.value}'),
              trailing: IconButton(icon: const Icon(Icons.copy), tooltip: 'Copy ${e.key}', onPressed: () => Clipboard.setData(ClipboardData(text: '${e.value}'))),
            ),
        ]),
      ),
    );
