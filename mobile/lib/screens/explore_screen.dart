import 'dart:async';

import 'package:flutter/material.dart';

import '../services/app_scope.dart';
import '../services/flixvault.dart';
import '../services/stream_media.dart';
import '../services/measurement.dart';
import '../theme.dart';
import '../widgets/ui.dart';
import 'channel_page.dart';
import 'post_page.dart';
import 'premium_screen.dart';

/// Shared post list used by Explore (all) and Feed (joined channels).
class PostList extends StatefulWidget {
  const PostList({super.key, this.joinedOnly = false, this.category, this.query = '', this.channelId, this.folderId, this.onDiscover});
  final bool joinedOnly;
  final String? channelId;
  /// Only posts in this channel folder (Flixvault folders).
  final String? folderId;
  final VoidCallback? onDiscover;
  final String? category;
  final String query;
  @override
  State<PostList> createState() => _PostListState();
}

class _PostListState extends State<PostList> {
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
        _thumbs.clear();
        _load(reset: true);
      });
    }
  }

  final _rows = <Map<String, dynamic>>[];
  final _thumbs = <String, String>{};
  bool _loading = true, _more = true, _fetching = false;
  int _gen = 0;
  bool _failed = false;
  int _pageSize = 0;
  String? _cursor;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  @override
  void didUpdateWidget(PostList old) {
    super.didUpdateWidget(old);
    if (old.category != widget.category || old.query != widget.query || old.channelId != widget.channelId || old.folderId != widget.folderId) _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_fetching && !reset) return;
    _fetching = true;
    final gen = ++_gen;
    if (reset) { _rows.clear(); _thumbs.clear(); _more = true; _failed = false; }
    if (mounted) setState(() => _loading = true);
    try {
      // Videos come from Flixvault; its server decides what this user may see.
      final List<Map<String, dynamic>> data;
      if (widget.joinedOnly) {
        data = _rows.isEmpty ? await Flixvault.following() : const [];
      } else if (widget.channelId != null) {
        final page = (await Flixvault.channel(widget.channelId!, before: _rows.isEmpty ? null : _cursor))?.posts ?? const <Map<String, dynamic>>[];
        _pageSize = page.length;
        if (page.isNotEmpty) _cursor = page.last['published_at'] as String?;
        data = widget.folderId == null ? page : page.where((p) => p['folder_id'] == widget.folderId).toList();
      } else {
        data = await Flixvault.explore(tab: widget.category ?? 'all', offset: _rows.length, search: widget.query);
      }
      if (gen != _gen || !mounted) return;
      final fresh = List<Map<String, dynamic>>.from(data);
      await _signThumbs(fresh, gen);
      if (gen != _gen || !mounted) return;
      _rows.addAll(fresh);
      _more = !widget.joinedOnly && (widget.channelId != null ? _pageSize >= 50 : data.length >= 30);
    } catch (_) {
      if (gen == _gen) { _failed = true; _more = false; }
    }
    if (gen != _gen) return;
    _fetching = false;
    if (mounted) setState(() => _loading = false);
  }

  Map? _first(Map<String, dynamic> r) {
    final items = (r['post_items'] as List?) ?? const [];
    if (items.isEmpty) return null;
    final sorted = [...items]..sort((a, b) => ((a as Map)['position'] as int? ?? 0).compareTo((b as Map)['position'] as int? ?? 0));
    return sorted.first as Map;
  }

  /// Short-lived links for the thumbnails on this page. Posts without a thumbnail just show the placeholder.
  Future<void> _signThumbs(List<Map<String, dynamic>> rows, int generation) async {
    final keys = <String>{
      for (final r in rows)
        if (_first(r)?['thumbnail_key'] is String) _first(r)!['thumbnail_key'] as String,
    }..removeAll(_thumbs.keys);
    if (keys.isEmpty) return;
    try {
      final links = await signMedia(keys, kind: 'thumbnail');
      if (mounted && generation == _gen) _thumbs.addAll(links);
    } catch (_) {/* cards fall back to the placeholder */}
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _rows.isEmpty) {
      return VideoGrid(itemCount: 6, itemBuilder: (_, __) => const _Skeleton());
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: _rows.isEmpty
          ? ListView(physics: const AlwaysScrollableScrollPhysics(), children: [
              const SizedBox(height: 24),
              if (_failed)
                EmptyState(icon: Icons.cloud_off_outlined, title: 'Could not load videos',
                  message: 'Check your connection and try again.', actionLabel: 'Retry', onAction: () => _load(reset: true))
              else if (widget.query.isNotEmpty)
                const EmptyState(icon: Icons.search_off_rounded, title: 'No matching videos', message: 'Try another title or clear your filters.')
              else if (widget.joinedOnly)
                EmptyState(icon: Icons.video_library_outlined, title: 'Your feed is empty',
                  message: 'Videos from channels you follow will appear here.',
                  actionLabel: 'Discover channels', onAction: widget.onDiscover)
              else
                const EmptyState(icon: Icons.video_library_outlined, title: 'No videos here yet', message: 'Check back later.'),
            ])
          : VideoGrid(
              itemCount: _rows.length + (_more ? 1 : 0),
              itemBuilder: (_, i) {
                if (i == _rows.length) {
                  WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _load(); });
                  return const Center(child: CircularProgressIndicator());
                }
                final post = _rows[i];
                final first = _first(post);
                return VideoCard(
                  title: post['title'] as String? ?? '',
                  channel: (post['channels'] as Map?)?['name'] as String? ?? '',
                  url: _thumbs[first?['thumbnail_key']],
                  seconds: first?['duration_s'] as int?,
                  premium: ((post['post_items'] as List?) ?? []).any((item) => item['is_premium'] == true),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PostPage(postId: post['id'] as String))),
                );
              },
            ),
    );
  }
}

class _Skeleton extends StatelessWidget {
  const _Skeleton();
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: AspectRatio(aspectRatio: 2 / 3, child: Container(
      decoration: BoxDecoration(color: Tokens.surface, borderRadius: BorderRadius.circular(14)),
    )),
  );
}

class ExploreScreen extends StatefulWidget {
  const ExploreScreen({super.key, this.searchRequest = 0});
  final int searchRequest;
  @override
  State<ExploreScreen> createState() => _ExploreScreenState();
}

class _ExploreScreenState extends State<ExploreScreen> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String? _cat;
  String _q = '';
  bool _showSearch = false;
  bool _searchChannels = false;
  static const tabs = {'all': 'All', 'latest': 'Latest', 'popular': 'Popular', 'most_watched': 'Most watched'};

  void _updateQuery(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _q = value.trim());
    });
  }

  @override
  void didUpdateWidget(ExploreScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.searchRequest != oldWidget.searchRequest) {
      _showSearch = true;
      _focusSearch();
    }
  }

  void _focusSearch() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _showSearch) _focus.requestFocus();
    });
  }

  void _toggleSearch() {
    _debounce?.cancel();
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _search.clear();
        _q = '';
        _searchChannels = false;
      }
    });
    if (_showSearch) _focusSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final status = app.status;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
        child: Row(children: [
          const Expanded(child: Text('Explore', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700))),
          IconButton(
            tooltip: _showSearch ? 'Close search' : 'Search videos and channels',
            icon: Icon(_showSearch ? Icons.close_rounded : Icons.search_rounded),
            onPressed: _toggleSearch,
          ),
          if (app.showPremiumEntry)
            IconButton(
              tooltip: 'Premium',
              icon: const Icon(Icons.workspace_premium, color: Tokens.gold),
              onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const PremiumScreen())),
            ),
        ]),
      ),
      if (_showSearch) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const Key('explore_search'),
            controller: _search,
            focusNode: _focus,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(hintText: 'Search videos and channels', prefixIcon: Icon(Icons.search), isDense: true),
            onChanged: _updateQuery,
            onSubmitted: (value) {
              _debounce?.cancel();
              setState(() => _q = value.trim());
              if (_q.isNotEmpty) Measurement.instance.track('SearchUsed');
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('Videos'), selected: !_searchChannels, onSelected: (_) => setState(() => _searchChannels = false)),
            ChoiceChip(label: const Text('Channels'), selected: _searchChannels, onSelected: (_) => setState(() => _searchChannels = true)),
          ]),
        ),
      ],
      if (!_searchChannels)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Row(children: [
            for (final t in tabs.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(visualDensity: VisualDensity.compact, label: Text(t.value), selected: (_cat ?? 'all') == t.key, onSelected: (_) => setState(() => _cat = t.key)),
              ),
          ]),
        ),
      Expanded(child: _searchChannels
          ? _ExploreChannelResults(
              key: ValueKey((status.raw['user_id'], status.source, status.isGuest, status.isPremium, status.hasAdsAccess, status.accessStatus)),
              query: _q,
            )
          : PostList(category: _cat, query: _q)),
    ]);
  }
}

class _ExploreChannelResults extends StatefulWidget {
  const _ExploreChannelResults({super.key, required this.query});
  final String query;

  @override
  State<_ExploreChannelResults> createState() => _ExploreChannelResultsState();
}

class _ExploreChannelResultsState extends State<_ExploreChannelResults> {
  late Future<List<Map<String, dynamic>>> _matches = _load();

  @override
  void didUpdateWidget(_ExploreChannelResults oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.query != oldWidget.query) _matches = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final term = widget.query.trim();
    if (term.isEmpty) return [];
    return Flixvault.channels(search: term);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _matches,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
      if (snapshot.hasError) {
        return ListView(children: [EmptyState(icon: Icons.cloud_off_outlined, title: 'Could not load channels',
          actionLabel: 'Retry', onAction: () => setState(() => _matches = _load()))]);
      }
      final results = snapshot.data ?? [];
      if (results.isEmpty) {
        return ListView(children: [EmptyState(icon: Icons.search_rounded,
          title: widget.query.isEmpty ? 'Search for a channel' : 'No matching channels')]);
      }
      return ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: results.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, index) {
          final row = results[index];
          final name = row['name'] as String? ?? '';
          final category = row['category'] as String?;
          return Card(child: ListTile(
            leading: InitialAvatar(name: name, url: row['icon_url'] as String?),
            title: Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: category == null || category.isEmpty ? null : Text(category),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ChannelPage(channelId: row['id'] as String, name: name))),
          ));
        },
      );
    },
  );
}
