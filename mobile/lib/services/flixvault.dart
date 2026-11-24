import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';

/// Videos come from Flixvault through Puffle's own `flixvault-feed` server
/// function. The server decides what this user may see and play (ads/organic,
/// Premium); the app only shows the result.
///
/// Rows are returned in the same shape the screens already used for Puffle's
/// own posts, so the screens and widgets stay the same. `thumbnail_key` holds a
/// ready-to-use public image URL (see `signMedia`, which passes URLs through).
class Flixvault {
  static Future<Map<String, dynamic>> _call(Map<String, dynamic> body) async {
    final Object? data;
    try {
      data = (await sb.functions.invoke('flixvault-feed', body: body)).data;
    } on FunctionException catch (e) {
      final d = e.details;
      throw FlixvaultError(d is Map && d['error'] != null ? d['error'].toString() : 'unavailable');
    }
    if (data is Map && data['error'] != null) throw FlixvaultError(data['error'].toString());
    return Map<String, dynamic>.from(data as Map);
  }

  /// tab: all | latest | popular | most_watched
  static Future<List<Map<String, dynamic>>> explore({String tab = 'all', int offset = 0, String? search}) async {
    final data = await _call({
      'action': 'explore',
      'tab': tab,
      'offset': offset,
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
    });
    return _posts(data['posts']);
  }

  /// Newest posts from the Flixvault channels this user follows.
  static Future<List<Map<String, dynamic>>> following() async => _posts((await _call({'action': 'following'}))['posts']);

  /// sort: trending | latest | top
  static Future<List<Map<String, dynamic>>> channels({String sort = 'trending', String? search}) async {
    final data = await _call({
      'action': 'channels',
      'sort': sort,
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
    });
    return [for (final c in (data['channels'] as List? ?? const [])) _channel(Map<String, dynamic>.from(c as Map))];
  }

  /// The channel and its newest posts, or null when it is not available to this user.
  static Future<({Map<String, dynamic> channel, List<Map<String, dynamic>> posts, List<Map<String, dynamic>> folders})?> channel(String id, {String? before}) async {
    try {
      final data = await _call({'action': 'channel', 'channel_id': id, if (before != null) 'before': before});
      return (
        channel: _channel(Map<String, dynamic>.from(data['channel'] as Map)),
        posts: _posts(data['posts']),
        folders: [for (final f in (data['folders'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)],
      );
    } on FlixvaultError catch (e) {
      if (e.code == 'not found') return null;
      rethrow;
    }
  }

  static Future<Map<String, dynamic>?> post(String id) async {
    try {
      final data = await _call({'action': 'post', 'post_id': id});
      return _post(Map<String, dynamic>.from(data['post'] as Map));
    } on FlixvaultError catch (e) {
      if (e.code == 'not found') return null;
      rethrow;
    }
  }

  /// Short-lived HLS link. kind: video | preview.
  /// Throws [FlixvaultError] with code premium_required / not_allowed / login_required.
  static Future<String> play(String itemId, {required String kind}) async {
    final data = await _call({'action': 'play', 'item_id': itemId, 'kind': kind});
    return data['url'] as String;
  }

  // ---- follows / blocks / reports are Puffle's own data -------------------------------
  static Future<Set<String>> followedIds() async {
    if (sb.auth.currentUser == null) return {};
    final rows = await sb.from('flixvault_follows').select('channel_id');
    return {for (final r in rows) r['channel_id'] as String};
  }

  static Future<void> setFollowing(String channelId, bool follow) async {
    if (follow) {
      await sb.from('flixvault_follows').upsert({'channel_id': channelId});
    } else {
      await sb.from('flixvault_follows').delete().eq('channel_id', channelId);
    }
  }

  static Future<void> block(String channelId) async {
    await sb.from('flixvault_blocks').upsert({'channel_id': channelId});
    await sb.from('flixvault_follows').delete().eq('channel_id', channelId);
  }

  /// Channels this user blocked, with names, so they can be unblocked.
  static Future<List<Map<String, dynamic>>> blockedChannels() async {
    if (sb.auth.currentUser == null) return const [];
    final ids = [for (final r in await sb.from('flixvault_blocks').select('channel_id')) r['channel_id'] as String];
    if (ids.isEmpty) return const [];
    final rows = await sb.from('flixvault_channels').select('id,name,icon_url').inFilter('id', ids).order('name');
    final named = {for (final r in rows) r['id'] as String: Map<String, dynamic>.from(r)};
    return [for (final id in ids) named[id] ?? {'id': id, 'name': 'Channel no longer available', 'icon_url': null}];
  }

  static Future<void> unblock(String channelId) =>
      sb.from('flixvault_blocks').delete().eq('channel_id', channelId);

  static Future<void> report(String postId, String reason) =>
      sb.from('flixvault_reports').insert({'post_id': postId, 'reason': reason});

  // ---- shape adapters ------------------------------------------------------------------
  static List<Map<String, dynamic>> _posts(Object? list) =>
      [for (final p in (list as List? ?? const [])) _post(Map<String, dynamic>.from(p as Map))];

  static Map<String, dynamic> _post(Map<String, dynamic> p) {
    final ch = Map<String, dynamic>.from((p['channel'] as Map?) ?? const {});
    final items = [
      for (final i in (p['items'] as List? ?? const []))
        () {
          final m = Map<String, dynamic>.from(i as Map);
          final image = m['kind'] == 'image';
          return <String, dynamic>{
            'id': m['id'],
            'kind': m['kind'],
            'is_premium': m['is_premium'] == true,
            'duration_s': (m['duration_s'] as num?)?.toInt(),
            'position': (m['position'] as num?)?.toInt() ?? 0,
            'thumbnail_key': m['thumb_url'],
            'mime': image ? 'image/jpeg' : 'video/mp4',
            'playable': m['playable'] == true,
            'has_preview': m['has_preview'] == true,
          };
        }(),
    ]..sort((a, b) => (a['position'] as int).compareTo(b['position'] as int));
    return {
      'id': p['id'],
      'title': p['title'] ?? '',
      'description': p['caption'],
      'created_at': p['published_at'],
      'published_at': p['published_at'],
      'channel_id': p['channel_id'],
      'folder_id': p['folder_id'],
      'view_count': p['view_count'],
      'channels': {'name': ch['name'] ?? '', 'category': null, 'icon_url': ch['icon_url']},
      'post_items': items,
    };
  }

  static Map<String, dynamic> _channel(Map<String, dynamic> c) => {
    'id': c['id'],
    'name': c['name'] ?? '',
    'description': c['description'],
    'category': c['category'],
    'icon_url': c['icon_url'],
    'members_count': (c['members_count'] as num?)?.toInt() ?? 0,
    'rating': (c['rating'] as num?)?.toDouble() ?? 0,
    'review_status': 'approved',
    'created_by': null,
    'created_at': c['created_at'],
  };
}

class FlixvaultError implements Exception {
  FlixvaultError(this.code);
  final String code;
  @override
  String toString() => 'FlixvaultError($code)';
}
