import 'dart:io' show Platform;

import 'package:advertising_id/advertising_id.dart';
import 'package:facebook_app_events/facebook_app_events.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Meta ad measurement (like Flixvault), only after the user allows ad
/// measurement in Puffle:
///  * switches on the Meta SDK's automatic events (it reports the install and
///    app opens, so Meta can credit installs from Meta ads);
///  * sends Puffle's server the SDK's anonymous install ID and the phone's
///    advertising ID (only when ad personalisation is NOT turned off), so Meta
///    can match sign-ups, checkouts and purchases to the same phone.
/// Sent once, and again only if one of them changes. Never blocks or breaks the app.
class MetaIds {
  static const _zeroId = '00000000-0000-0000-0000-000000000000';

  static Future<void> sync({required bool allowed}) async {
    if (kIsWeb || !Platform.isAndroid) return;
    try {
      final fb = FacebookAppEvents();
      await fb.setAutoLogAppEventsEnabled(allowed);
      if (!allowed) return;
      final prefs = await SharedPreferences.getInstance();
      final installId = prefs.getString('install_id');
      if (installId == null || Supabase.instance.client.auth.currentUser == null) return;
      final anonId = await fb.getAnonymousId();
      String? adId;
      try {
        final limited = await AdvertisingId.isLimitAdTrackingEnabled ?? true;
        if (!limited) {
          final id = await AdvertisingId.id(false);
          if (id != null && id.isNotEmpty && id != _zeroId) adId = id;
        }
      } catch (_) {
        // No Google Play services: no advertising ID.
      }
      final key = '$installId|${anonId ?? ''}|${adId ?? ''}';
      if (prefs.getString('meta_ids_sent') == key) return;
      await Supabase.instance.client.rpc('record_ad_ids',
          params: {'p_install_id': installId, 'p_fb_anon_id': anonId, 'p_ad_id': adId});
      await prefs.setString('meta_ids_sent', key);
    } catch (_) {
      // Measurement must never break the app; tried again next launch.
    }
  }
}
