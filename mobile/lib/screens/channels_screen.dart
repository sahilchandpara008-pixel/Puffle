import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../services/app_scope.dart';
import '../services/flixvault.dart';
import '../services/measurement.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'channel_page.dart';
import 'login_sheet.dart';

class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, this.standalone = false});
  /// True when opened from Profile > My channels (adds a back button).
  final bool standalone;
  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

enum _ChannelOrder { members, latest, top }

class _ChannelsScreenState extends State<ChannelsScreen> {
  String? _accessKey;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.of(context);
    final status = app.status;
    final key = '${app.loaded}|${status.raw['user_id']}|${status.source}|${status.isGuest}|${status.hasAdsAccess}|${status.isPremium}|${status.accessStatus}';
    final previous = _accessKey;
    _accessKey = key;
    if (previous != null && previous != key) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _accessKey != key) return;
        setState(() { _rows = []; _joined = {}; _loading = true; });
        _load();
      });
    }
  }

  List<Map<String, dynamic>> _rows = [];
  Set<String> _joined = {};
  bool _loading = true;
  bool _showJoined = false;
  _ChannelOrder _order = _ChannelOrder.members;

  @override
  void initState() {
    super.initState();
    _load();
  }

  int _loadGeneration = 0;
  Future<void> _load() async {
    final generation = ++_loadGeneration;
    try {
      // Flixvault channels this user may see (its server applies ads/organic); follows are Puffle's own.
      final data = await Flixvault.channels();
      final follows = await Flixvault.followedIds();
      if (!mounted || generation != _loadGeneration) return;
      _joined = follows;
      _rows = widget.standalone ? data.where((row) => _joined.contains(row['id'])).toList() : data;
    } catch (_) {}
    if (mounted && generation == _loadGeneration) setState(() => _loading = false);
  }

  Future<void> _toggle(String id) async {
    if (!await requireAccount(context) || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final follow = !_joined.contains(id);
      await Flixvault.setFollowing(id, follow);
      if (follow) Measurement.instance.track('ChannelJoined');
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not update. Please try again.')));
    }
    await _load();
  }

  Future<void> _showBlocked() async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _BlockedChannelsSheet(),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _search() async {
    final joinedOnly = widget.standalone || _showJoined;
    final selected = await showSearch<Map<String, dynamic>?>(
      context: context,
      delegate: JoinedChannelSearch(rows: _rows, joined: _joined, onlyJoined: joinedOnly),
    );
    if (selected == null || !mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelPage(
      channelId: selected['id'] as String, name: selected['name'] as String? ?? '',
    )));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    AppScope.of(context);
    final rows = _rows.where((row) => !_showJoined || _joined.contains(row['id'])).toList();
    rows.sort((first, second) {
      if (_order == _ChannelOrder.top) {
        final rating = ((second['rating'] as num?) ?? 0).compareTo((first['rating'] as num?) ?? 0);
        if (rating != 0) return rating;
      }
      if (_order == _ChannelOrder.members) {
        final members = (second['members_count'] as int? ?? 0).compareTo(first['members_count'] as int? ?? 0);
        if (members != 0) return members;
      }
      return (second['created_at'] as String? ?? '').compareTo(first['created_at'] as String? ?? '');
    });
    return Scaffold(
      backgroundColor: widget.standalone ? Tokens.background : Colors.transparent,
      appBar: AppBar(
        title: Text(widget.standalone ? 'My channels' : 'Channels'),
        automaticallyImplyLeading: widget.standalone,
        actions: [
          IconButton(tooltip: widget.standalone || _showJoined ? 'Search joined channels' : 'Search channels', icon: const Icon(Icons.search_rounded), onPressed: _loading ? null : _search),
          PopupMenuButton<String>(
            tooltip: 'More',
            onSelected: (_) => _showBlocked(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'blocked', child: Text('Blocked channels'))],
          ),
        ],
      ),
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (!widget.standalone)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              ChoiceChip(label: const Text('Discover'), selected: !_showJoined, onSelected: (_) => setState(() => _showJoined = false)),
              ChoiceChip(label: const Text('Joined'), selected: _showJoined, onSelected: (_) => setState(() => _showJoined = true)),
              PopupMenuButton<_ChannelOrder>(
                tooltip: 'Sort channels',
                icon: const Icon(Icons.sort_rounded),
                initialValue: _order,
                onSelected: (order) => setState(() => _order = order),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: _ChannelOrder.members, child: Text('Most members')),
                  PopupMenuItem(value: _ChannelOrder.latest, child: Text('Latest')),
                  PopupMenuItem(value: _ChannelOrder.top, child: Text('Top rated')),
                ],
              ),
            ]),
          ),
        Expanded(child: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: rows.isEmpty
                  ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
                      const SizedBox(height: 56),
                      EmptyState(
                        icon: Icons.live_tv_rounded,
                        title: _showJoined ? 'No joined channels' : widget.standalone ? 'No joined channels yet' : 'No channels yet',
                        message: _showJoined ? 'Channels you join will appear here.' : widget.standalone ? 'Channels you join show up here.' : 'Check back soon.',
                        actionLabel: _showJoined ? 'Discover channels' : null,
                        onAction: _showJoined ? () => setState(() => _showJoined = false) : null,
                      ),
                    ])
                  : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 88), physics: const AlwaysScrollableScrollPhysics(), children: [
                      for (final r in rows)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Container(
                            decoration: BoxDecoration(color: Tokens.surface, borderRadius: BorderRadius.circular(16), border: Border.all(color: Tokens.border)),
                            child: ListTile(
                              contentPadding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
                              onTap: () async {
                                await Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelPage(channelId: r['id'] as String, name: (r['name'] as String?) ?? '')));
                                _load();
                              },
                              leading: InitialAvatar(name: (r['name'] as String?) ?? '', size: 42, url: r['icon_url'] as String?),
                              title: Text(r['name'] ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                              subtitle: Text(
                                r['review_status'] == 'pending' ? 'Waiting for approval' : r['review_status'] == 'rejected' ? 'Not approved' : '${NumberFormat.compact().format(r['members_count'] ?? 0)} members',
                                style: TextStyle(color: r['review_status'] == 'pending' ? Tokens.warning : r['review_status'] == 'rejected' ? Tokens.danger : Tokens.muted, fontSize: 12),
                              ),
                              trailing: r['review_status'] != 'approved'
                                  ? null
                                  : _joined.contains(r['id'])
                                      ? OutlinedButton(
                                          style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 14)),
                                          onPressed: () => _toggle(r['id'] as String),
                                          child: const Text('Joined'),
                                        )
                                      : FilledButton(
                                          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, minimumSize: const Size(64, 36), padding: const EdgeInsets.symmetric(horizontal: 16)),
                                          onPressed: () => _toggle(r['id'] as String),
                                          child: const Text('Join'),
                                        ),
                            ),
                          ),
                        ),
                    ]),
            )),
      ]),
    );
  }
}

/// Search the loaded channels, restricted to memberships when opened from Joined.
class JoinedChannelSearch extends SearchDelegate<Map<String, dynamic>?> {
  JoinedChannelSearch({required List<Map<String, dynamic>> rows, required Set<String> joined, this.onlyJoined = true})
      : _rows = onlyJoined ? rows.where((r) => joined.contains(r['id'])).toList() : rows,
        super(searchFieldLabel: onlyJoined ? 'Search joined channels' : 'Search channels');
  final bool onlyJoined;
  final List<Map<String, dynamic>> _rows;

  @override
  List<Widget> buildActions(BuildContext context) => [
    if (query.isNotEmpty) IconButton(tooltip: 'Clear search', icon: const Icon(Icons.clear_rounded), onPressed: () => query = ''),
  ];
  @override
  Widget buildLeading(BuildContext context) => IconButton(
    tooltip: 'Back', icon: const Icon(Icons.arrow_back_rounded), onPressed: () => close(context, null),
  );
  @override
  Widget buildResults(BuildContext context) => _results(context);
  @override
  Widget buildSuggestions(BuildContext context) => _results(context);

  Widget _results(BuildContext context) {
    final term = query.trim().toLowerCase();
    final matches = _rows.where((r) => (r['name'] as String? ?? '').toLowerCase().contains(term)).toList();
    if (matches.isEmpty) return Center(child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(onlyJoined && _rows.isEmpty ? 'Join a channel to find it here.' : onlyJoined ? 'No joined channels match your search.' : 'No channels match your search.', textAlign: TextAlign.center),
    ));
    return ListView.builder(itemCount: matches.length, itemBuilder: (context, index) {
      final row = matches[index];
      final name = row['name'] as String? ?? '';
      return ListTile(leading: InitialAvatar(name: name, size: 42, url: row['icon_url'] as String?), title: Text(name),
        subtitle: onlyJoined ? const Text('Joined channel') : null, onTap: () => close(context, row));
    });
  }
}

/// Blocked channels, each with an Unblock button. Returns true when something changed.
class _BlockedChannelsSheet extends StatefulWidget {
  const _BlockedChannelsSheet();
  @override
  State<_BlockedChannelsSheet> createState() => _BlockedChannelsSheetState();
}

class _BlockedChannelsSheetState extends State<_BlockedChannelsSheet> {
  late Future<List<Map<String, dynamic>>> _rows = Flixvault.blockedChannels();
  bool _changed = false;

  Future<void> _unblock(String id) async {
    try {
      await Flixvault.unblock(id);
      _changed = true;
      setState(() => _rows = Flixvault.blockedChannels());
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not unblock. Please try again.')));
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) { if (!didPop) Navigator.pop(context, _changed); },
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const SheetHandle(),
        const SizedBox(height: 12),
        const Text('Blocked channels', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        FutureBuilder<List<Map<String, dynamic>>>(
          future: _rows,
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
            }
            final rows = snap.data ?? const [];
            if (rows.isEmpty) {
              return const Padding(padding: EdgeInsets.all(24), child: Text('You have not blocked any channels.', textAlign: TextAlign.center));
            }
            return ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .6),
              child: ListView(shrinkWrap: true, children: [
                for (final r in rows)
                  ListTile(
                    leading: InitialAvatar(name: r['name'] as String? ?? '', size: 40, url: r['icon_url'] as String?),
                    title: Text(r['name'] as String? ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: OutlinedButton(onPressed: () => _unblock(r['id'] as String), child: const Text('Unblock')),
                  ),
              ]),
            );
          },
        ),
        const SizedBox(height: 8),
        TextButton(onPressed: () => Navigator.pop(context, _changed), child: const Text('Done')),
      ]),
    ),
  );
}
