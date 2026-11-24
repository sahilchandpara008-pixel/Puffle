import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/app_scope.dart';
import '../services/app_state.dart';
import '../services/measurement.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'channel_page.dart';
import 'login_sheet.dart';
import 'premium_screen.dart';

class ChannelsScreen extends StatefulWidget {
  const ChannelsScreen({super.key, this.standalone = false});
  /// True when opened from Profile > My channels (adds a back button).
  final bool standalone;
  @override
  State<ChannelsScreen> createState() => _ChannelsScreenState();
}

enum _ChannelOrder { members, latest }

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
      // RLS returns only approved, visible, audience-matching channels (plus the user's own pending ones).
      final uid = sb.auth.currentUser?.id;
      final data = await sb.from('channels').select('id,name,description,category,members_count,review_status,created_by,created_at').order('members_count', ascending: false);
      final memberships = uid == null
          ? <Map<String, dynamic>>[]
          : await sb.from('channel_members').select('channel_id').eq('user_id', uid);
      if (!mounted || generation != _loadGeneration) return;
      _joined = {for (final row in memberships) row['channel_id'] as String};
      _rows = widget.standalone
          ? data.where((row) => (uid != null && row['created_by'] == uid) || _joined.contains(row['id'])).toList()
          : data;
    } catch (_) {}
    if (mounted && generation == _loadGeneration) setState(() => _loading = false);
  }

  Future<void> _toggle(String id) async {
    if (!await requireAccount(context) || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final uid = sb.auth.currentUser!.id;
      if (_joined.contains(id)) {
        await sb.from('channel_members').delete().eq('channel_id', id).eq('user_id', uid);
      } else {
        await sb.from('channel_members').insert({'channel_id': id, 'user_id': uid});
        Measurement.instance.track('ChannelJoined');
      }
    } catch (_) {
      messenger.showSnackBar(const SnackBar(content: Text('Could not update. Please try again.')));
    }
    await _load();
  }

  Future<void> _create() async {
    final app = AppScope.of(context);
    if (!app.status.isPremium) {
      await Navigator.push(context, MaterialPageRoute(builder: (_) => const PremiumScreen()));
      return;
    }
    if (!await requireAccount(context) || !mounted) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _CreateChannelSheet(),
    );
    if (ok != true || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Channel created and sent for approval. The admin will choose who can see it.')));
    await _load();
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
        actions: [IconButton(tooltip: widget.standalone || _showJoined ? 'Search joined channels' : 'Search channels', icon: const Icon(Icons.search_rounded), onPressed: _loading ? null : _search)],
      ),
      floatingActionButton: FloatingActionButton.extended(onPressed: _create, icon: const Icon(Icons.add), label: const Text('Create')),
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
                        title: _showJoined ? 'No joined channels' : widget.standalone ? 'No channels of your own yet' : 'No channels yet',
                        message: _showJoined ? 'Channels you join will appear here.' : widget.standalone ? 'Channels you create or join show up here.' : 'Start the first one. New channels are reviewed before everyone can see them.',
                        actionLabel: _showJoined ? 'Discover channels' : 'Create a channel',
                        onAction: _showJoined ? () => setState(() => _showJoined = false) : _create,
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
                              leading: InitialAvatar(name: (r['name'] as String?) ?? '', size: 42),
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
      return ListTile(leading: InitialAvatar(name: name, size: 42), title: Text(name),
        subtitle: onlyJoined ? const Text('Joined channel') : null, onTap: () => close(context, row));
    });
  }
}

/// Bottom sheet for starting a channel. Returns true once the channel is saved.
class _CreateChannelSheet extends StatefulWidget {
  const _CreateChannelSheet();
  @override
  State<_CreateChannelSheet> createState() => _CreateChannelSheetState();
}

class _CreateChannelSheetState extends State<_CreateChannelSheet> {
  final _name = TextEditingController();
  final _desc = TextEditingController();
  bool _busy = false;
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _desc.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.length < 3) return setState(() => _err = 'Give your channel a name of at least 3 letters.');
    setState(() { _busy = true; _err = null; });
    try {
      await sb.from('channels').insert({'name': name, 'description': _desc.text.trim()});
      Measurement.instance.track('ChannelCreated');
      if (mounted) Navigator.pop(context, true);
      return;
    } on PostgrestException catch (e) {
      _err = e.message;
    } catch (_) {
      _err = 'Could not create the channel. Check your connection and try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.fromLTRB(20, 10, 20, MediaQuery.of(context).viewInsets.bottom + 20),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const SheetHandle(),
            const SizedBox(height: 18),
            const Text('Create a channel', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            const Text('A place to share your videos with members.', style: TextStyle(color: Tokens.muted, fontSize: 13)),
            const SizedBox(height: 18),
            TextField(
              key: const Key('channel_name'),
              controller: _name,
              maxLength: 40,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'Channel name', prefixIcon: Icon(Icons.live_tv_rounded, size: 20)),
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _desc,
              maxLength: 200,
              minLines: 3,
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(labelText: 'What is it about? (optional)', alignLabelWithHint: true),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Tokens.primary.withValues(alpha: .08), borderRadius: BorderRadius.circular(12)),
              child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.verified_user_outlined, size: 18, color: Tokens.primary),
                SizedBox(width: 10),
                Expanded(child: Text('We review every new channel. You can post as soon as it is approved.', style: TextStyle(color: Tokens.muted, fontSize: 12, height: 1.4))),
              ]),
            ),
            if (_err != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_err!, style: const TextStyle(color: Tokens.danger, fontSize: 13))),
            const SizedBox(height: 16),
            GradientButton(label: _busy ? 'Creating…' : 'Create', onPressed: _busy ? null : _submit),
            const SizedBox(height: 4),
            TextButton(onPressed: _busy ? null : () => Navigator.pop(context, false), child: const Text('Cancel', style: TextStyle(color: Tokens.muted))),
          ]),
        ),
      );
}
