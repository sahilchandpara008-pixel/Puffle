import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/app_state.dart';
import '../theme.dart';

typedef PlansLoader = Future<List<Map<String, dynamic>>> Function();

Future<List<Map<String, dynamic>>> defaultPlansLoader() async {
  final r = await sb.rpc('public_plans');
  return [for (final e in (r as List)) Map<String, dynamic>.from(e as Map)];
}

String durationLabel(int days, [int hours = 0]) {
  if (hours > 0) {
    if (hours % 24 == 0) return durationLabel(hours ~/ 24);
    return hours == 1 ? '1 Hour' : '$hours Hours';
  }
  if (days >= 365 && days % 365 == 0) {
    final y = days ~/ 365;
    return y == 1 ? '1 Year' : '$y Years';
  }
  if (days >= 30 && days % 30 == 0) {
    final m = days ~/ 30;
    return m == 1 ? '1 Month' : '$m Months';
  }
  return days == 1 ? '1 Day' : '$days Days';
}

String perDay(num price, int days, [int hours = 0]) {
  final d = hours > 0 ? hours / 24 : days.toDouble();
  final v = price / (d <= 0 ? 1 : d);
  final s = v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// "Go Premium": the plans page. Prices and durations come from the server (public_plans);
/// the buy decision and amount are re-checked by the server in create_order.
class PlansPage extends StatefulWidget {
  const PlansPage({
    super.key,
    required this.onBuy,
    this.plansLoader,
    this.freeIds = const {},
    this.paused = false,
    this.actions = const [],
    this.showHeader = true,
  });
  final Future<void> Function(String planId) onBuy;
  final PlansLoader? plansLoader;
  final Set<String> freeIds;
  final bool paused;
  final List<Widget> actions;
  final bool showHeader;

  @override
  State<PlansPage> createState() => _PlansPageState();
}

class _PlansPageState extends State<PlansPage> {
  List<Map<String, dynamic>> _plans = [];
  bool _loading = true, _error = false, _busy = false;
  String? _selected;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = false; });
    try {
      final l = await (widget.plansLoader ?? defaultPlansLoader)();
      l.sort((a, b) => ((a['position'] as num?) ?? 0).compareTo((b['position'] as num?) ?? 0));
      _plans = l;
      final pop = l.where((p) => p['badge'] == 'Popular' || p['badge'] == 'Best value').toList()
        ..sort((a, b) => (a['badge'] == 'Popular' ? 0 : 1).compareTo(b['badge'] == 'Popular' ? 0 : 1));
      _selected = (pop.isNotEmpty ? pop.first : (l.isNotEmpty ? l.first : null))?['id'] as String?;
    } catch (_) {
      _error = true;
    }
    if (mounted) setState(() => _loading = false);
  }

  Map<String, dynamic>? get _sel {
    for (final p in _plans) {
      if (p['id'] == _selected) return p;
    }
    return null;
  }

  Future<void> _buy() async {
    final id = _selected;
    if (id == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.onBuy(id);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String path) => launchUrl(Uri.parse('${Config.websiteUrl}$path'), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    final sel = _sel;
    final isFree = sel != null && widget.freeIds.contains(sel['id']);
    final cta = sel == null
        ? 'Choose a plan'
        : isFree
            ? 'Claim free ${sel['name']} Plan'
            : 'Continue with ${sel['name']} · ₹${sel['price_inr']}';
    final standardRates = _plans.where((p) => !widget.freeIds.contains(p['id']) && (p['price_inr'] as num) > 0)
        .map(_rate).toList()..sort();
    final topRate = standardRates.isEmpty ? 0.0 : standardRates.last;
    return Container(
      key: const Key('plans_page'),
      decoration: BoxDecoration(
        gradient: RadialGradient(center: const Alignment(0, -1.1), radius: 1.2, colors: [Tokens.primary.withValues(alpha: .28), Tokens.background]),
      ),
      child: Column(children: [
        Expanded(
          child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 8), children: [
            if (widget.showHeader)
              Row(children: [
                const Icon(Icons.workspace_premium, color: Tokens.gold, size: 30),
                const SizedBox(width: 10),
                const Expanded(child: Text('Go Premium', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700))),
                ...widget.actions,
              ]),
            const Text('One-time UPI payment · No auto-renewal',
              style: TextStyle(color: Tokens.muted, fontSize: 13)),
            const SizedBox(height: 8),
            const Wrap(spacing: 6, runSpacing: 4, children: [
              _Perk(Icons.cloud_outlined, '2 TB cloud'),
              _Perk(Icons.play_circle_outline, 'Full videos'),
              _Perk(Icons.download_outlined, 'Offline downloads'),
            ]),
            const SizedBox(height: 10),
            const Text('Choose your plan', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            if (widget.paused)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Tokens.warning.withValues(alpha: .15), borderRadius: BorderRadius.circular(12)),
                child: const Text('Payments are paused right now. Please try again later.'),
              ),
            if (_loading)
              const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator()))
            else if (_error)
              Center(child: Column(children: [
                const Text("Couldn't load plans"),
                TextButton(onPressed: _load, child: const Text('Retry')),
              ]))
            else
              for (final p in _plans)
                _PlanTile(plan: p, selected: p['id'] == _selected, free: widget.freeIds.contains(p['id']),
                  savings: topRate > 0 ? ((1 - _rate(p) / topRate) * 100).floor().clamp(0, 100).toInt() : 0,
                  onTap: () => setState(() => _selected = p['id'] as String)),
            Wrap(alignment: WrapAlignment.center, children: [
              TextButton(key: const Key('link_privacy'), onPressed: () => _open('/privacy'), child: const Text('Privacy Policy', style: TextStyle(color: Tokens.muted, fontSize: 12))),
              TextButton(key: const Key('link_terms'), onPressed: () => _open('/terms'), child: const Text('Terms & Conditions', style: TextStyle(color: Tokens.muted, fontSize: 12))),
              TextButton(key: const Key('link_refund'), onPressed: () => _open('/refund'), child: const Text('Refund Policy', style: TextStyle(color: Tokens.muted, fontSize: 12))),
              TextButton(onPressed: () => launchUrl(Uri(scheme: 'mailto', path: Config.supportEmail)),
                  child: const Text('Email support', style: TextStyle(color: Tokens.muted, fontSize: 12))),
            ]),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: SizedBox(
            width: double.infinity,
            child: GradientButton(label: _busy ? 'Please wait…' : cta, onPressed: (sel == null || _busy || (widget.paused && !isFree)) ? null : _buy),
          ),
        ),
      ]),
    );
  }
}

double _rate(Map<String, dynamic> plan) {
  final hours = (plan['duration_hours'] as num?) ?? 0;
  final days = hours > 0 ? hours / 24 : ((plan['duration_days'] as num?) ?? 1);
  return (plan['price_inr'] as num) / (days > 0 ? days : 1);
}

class _Perk extends StatelessWidget {
  const _Perk(this.icon, this.text);
  final IconData icon;
  final String text;
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 8),
        decoration: BoxDecoration(color: Tokens.surface, borderRadius: BorderRadius.circular(18), border: Border.all(color: Tokens.border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: Tokens.accent, size: 15),
          const SizedBox(width: 4),
          Flexible(child: Text(text, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))),
        ]),
      );
}

class _PlanTile extends StatelessWidget {
  const _PlanTile({required this.plan, required this.selected, required this.free, required this.onTap, required this.savings});
  final Map<String, dynamic> plan;
  final bool selected, free;
  final int savings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final days = (plan['duration_days'] as num).toInt();
    final hours = ((plan['duration_hours'] ?? 0) as num).toInt();
    final price = plan['price_inr'] as num;
    final badge = plan['badge'] as String?;
    final detailStyle = TextStyle(color: selected ? Colors.white.withValues(alpha: .9) : Tokens.muted, fontSize: 12);
    final badgeStyle = TextStyle(color: selected ? Colors.white : Tokens.accent, fontSize: 10, fontWeight: FontWeight.w600);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Semantics(
        selected: selected,
        button: true,
        child: Material(
          color: Colors.transparent,
          child: Ink(
            decoration: BoxDecoration(
              gradient: selected ? Tokens.gradient : null,
              color: selected ? null : Tokens.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? Tokens.accent : Tokens.border),
            ),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                child: Row(children: [
                  Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    color: selected ? Colors.white : Tokens.muted, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 3,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${plan['name']} Plan', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                      Text(durationLabel(days, hours), style: detailStyle),
                      if (badge != null || (!free && savings > 0))
                        Wrap(spacing: 6, children: [
                          if (badge != null)
                            Text(badge == 'Popular' ? 'MOST POPULAR' : badge.toUpperCase(), style: badgeStyle),
                          if (!free && savings > 0) Text('SAVE $savings%', style: badgeStyle),
                        ]),
                    ]),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 2,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text(free ? 'FREE' : '₹$price', textAlign: TextAlign.end,
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      if (!free && (hours == 0 || hours >= 24))
                        Text('₹${perDay(price, days, hours)}/day', textAlign: TextAlign.end, style: detailStyle),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
