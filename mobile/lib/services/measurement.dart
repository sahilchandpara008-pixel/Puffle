import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'google_measurement.dart';
import 'install_attribution.dart';
import 'meta_ids.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../config.dart';

/// Optional measurement only. Keys, prices and purchase authority stay on the server.
class Measurement extends ChangeNotifier {
  static final instance=Measurement();
  final _uuid=const Uuid();
  SupabaseClient get _sb=>Supabase.instance.client;
  bool analytics=false, advertising=false, google=false, ready=false, hasChoice=false;
  String? _uid;
  String _session=const Uuid().v4();
  DateTime _lastActive=DateTime.now();
  bool _busy=false;
  Future<void> _writing=Future.value();
  Future<void> _serial(Future<void> Function() f) {final next=_writing.then((_)=>f());_writing=next.catchError((Object _){});return next;}
  static const _pendingKey = 'pending_onboarding_measurement';
  bool _choicePending = false;
  Future<void> _preferences = Future.value();

  Future<void> _writePreferences(Future<void> Function() operation) {
    final next = _preferences.then((_) => operation());
    _preferences = next.catchError((Object _) {});
    return next;
  }

  Future<void> saveOnboardingChoice(bool allow) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = await prefs.setString(_pendingKey,
      jsonEncode({'uid': _sb.auth.currentUser?.id, 'allow': allow}));
    if (!stored) throw StateError('Could not write the local preference');
    _choicePending = true;
    unawaited(start());
  }

  Future<void> start() => _writePreferences(_start);

  bool get googleSharingEnabled => !_choicePending && google;

  Future<void> retryOnboardingChoice() async {
    if (_choicePending) await start();
  }

  Future<void> _start() async {
    final uid=_sb.auth.currentUser?.id;
    final prefs = await SharedPreferences.getInstance();
    final pending = prefs.getString(_pendingKey);
    _choicePending = pending != null;
    if(uid==null)return;
    if (pending != null) {
      final choice = jsonDecode(pending) as Map;
      if (choice['uid'] == null || choice['uid'] == uid) {
        _uid = uid;
        if (choice['uid'] == null) {
          await prefs.setString(_pendingKey, jsonEncode({'uid': uid, 'allow': choice['allow']}));
        }
        try {
          final allow = choice['allow'] == true;
          await _save(allow, allow, allow);
        } catch (_) {
          ready = false;
          notifyListeners();
          return;
        }
        await prefs.remove(_pendingKey);
        _choicePending = false;
        await track('AppOpen');
        return;
      }
      await prefs.remove(_pendingKey);
      _choicePending = false;
    }
    if(_uid!=uid){_uid=uid;ready=false;analytics=false;advertising=false;google=false;hasChoice=false;
      final p=await SharedPreferences.getInstance();
      hasChoice=p.containsKey('measurement_choice_$uid');
      if(hasChoice){final v=jsonDecode(p.getString('measurement_choice_$uid')!) as Map;analytics=v['analytics']==true;advertising=v['advertising']==true;google=v['google']==true;}
      // A server revocation wins over a stale device preference.
      try{final row=await _sb.from('measurement_preferences').select('analytics,advertising').eq('user_id',uid).maybeSingle();
        if(row!=null){analytics=row['analytics']==true;advertising=row['advertising']==true;hasChoice=true;}}catch(_){}
    }
    try{final g=await _sb.from('google_preferences').select('enabled').eq('user_id',uid).maybeSingle();if(g!=null)google=g['enabled']==true;}catch(_){}
    try{await _sync();}catch(_){ready=false;notifyListeners();return;}
    await GoogleMeasurement.instance.sync(google,force:true);
    ready=true;notifyListeners();await track('AppOpen');unawaited(flush());
  }
  Future<Map<String,dynamic>> _context() async{
    if(!advertising)return {};
    final p=await SharedPreferences.getInstance();
    final id=p.getString('install_id')??_uuid.v4();await p.setString('install_id',id);
    Map<String, dynamic> native = {};
    try {
      native = await const MethodChannel('app/measurement').invokeMapMethod<String, dynamic>('context') ?? {};
    } on PlatformException {
      // Fall back to the runtime version if Android metadata is temporarily unavailable.
    } on MissingPluginException {
      // A missing optional metadata channel must not prevent saving the choice.
    }
    final nativeOs = (native['os'] as String?)?.trim() ?? '';
    final os = nativeOs.isEmpty ? Platform.operatingSystemVersion.trim() : nativeOs;
    final view=PlatformDispatcher.instance.views.first;
    return {'install_id':id,'extinfo':['a2','com.pufflecloud.app','14',Config.versionLabel,
      os,'${native['model']??''}',PlatformDispatcher.instance.locale.toLanguageTag(),DateTime.now().timeZoneName,'',
      view.physicalSize.width.round().toString(),view.physicalSize.height.round().toString(),view.devicePixelRatio.toString(),'${native['cores']??''}','','',''].map((value) => value.length > 120 ? value.substring(0, 120) : value).toList()};
  }
  Future<void> _sync() async {
    await _sb.rpc('set_measurement_preferences',params:{'p_analytics':analytics,'p_advertising':advertising,'p_context':await _context()});
    if(advertising){try{await InstallAttribution.record(forceLink:true);}catch(_){/* Attribution never blocks a consent choice. */}}
    unawaited(MetaIds.sync(allowed: advertising));
  }
  Future<void> save(bool usage, bool ads, [bool googleAds = false]) => _writePreferences(() async {
    await _save(usage, ads, googleAds);
    if (_choicePending) {
      await (await SharedPreferences.getInstance()).remove(_pendingKey);
      _choicePending = false;
    }
  });

  Future<void> _save(bool usage,bool ads,bool googleAds) async{
    final oldA=analytics,oldD=advertising,oldG=google;analytics=usage;advertising=ads;google=googleAds;
    try{await _sync();await _sb.rpc('set_google_preferences',params:{'p_enabled':google});}catch(_){analytics=oldA;advertising=oldD;google=oldG;rethrow;}
    await GoogleMeasurement.instance.sync(google,force:true);if(!google)await GoogleMeasurement.instance.revoke();
    ready=true;hasChoice=true;final uid=_sb.auth.currentUser!.id;
    final p=await SharedPreferences.getInstance();
    await p.setString('measurement_choice_$uid',jsonEncode({'analytics':usage,'advertising':ads,'google':google}));
    if(!usage&&!ads)await _serial(()async{await p.remove('measurement_queue');});
    notifyListeners();if(usage||ads||google){await track('AppOpen');unawaited(flush());}
  }
  Future<void> resumed() async{
    await retryOnboardingChoice();
    if(DateTime.now().difference(_lastActive)>const Duration(minutes:30))_session=_uuid.v4();
    _lastActive=DateTime.now();await track('AppOpen');unawaited(flush());
  }
  Future<void> track(String name,[Map<String,dynamic> properties=const {}]) async{
    if(_choicePending||!ready||_uid!=_sb.auth.currentUser?.id)return;
    unawaited(GoogleMeasurement.instance.track(name,properties));
    // Registration is authoritative on the server for Meta; only Firebase needs this SDK signal.
    if(name=='CompleteRegistration')return;
    if(!analytics&&!advertising)return;
    final event={'uid':_uid,'p_event_id':_uuid.v4(),'p_name':name,'p_session_id':_session,'p_properties':properties,'p_occurred_at':DateTime.now().toUtc().toIso8601String()};
    await _serial(()async{final p=await SharedPreferences.getInstance();final rows=_read(p)..add(event);if(rows.length>200)rows.removeRange(0,rows.length-200);await p.setString('measurement_queue',jsonEncode(rows));});
    unawaited(flush());
  }
  List<Map<String,dynamic>> _read(SharedPreferences p){try{return (jsonDecode(p.getString('measurement_queue')??'[]') as List).map((x)=>Map<String,dynamic>.from(x as Map)).where((x)=>DateTime.tryParse(x['p_occurred_at'] as String? ??'')?.isAfter(DateTime.now().subtract(const Duration(days:1)))??false).toList();}catch(_){return [];}}
  Future<void> flush() async{
    if(_choicePending||_busy||!ready||(!analytics&&!advertising))return;_busy=true;
    try{
      for(var i=0;i<200;i++){
        final p=await SharedPreferences.getInstance();Map<String,dynamic>? row;
        await _serial(()async{final rows=_read(p);if(rows.isNotEmpty)row=rows.first;});
        if(row==null)break;
        if(row!['uid']==_sb.auth.currentUser?.id){final params=Map<String,dynamic>.from(row!)..remove('uid');await _sb.rpc('record_activity',params:params);}
        await _serial(()async{final rows=_read(p)..removeWhere((x)=>x['p_event_id']==row!['p_event_id']);await p.setString('measurement_queue',jsonEncode(rows));});
        if(_choicePending||(!analytics&&!advertising))break;
      }
    }catch(_){/* Best-effort bounded retry, never blocks app use or payments. */}
    finally{_busy=false;}
  }
}
