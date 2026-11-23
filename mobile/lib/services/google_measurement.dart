import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../config.dart';

/// Native events use Firebase, never a website conversion tag inside a hidden WebView.
class GoogleMeasurement {
 static final instance=GoogleMeasurement();
 SupabaseClient get _sb=>Supabase.instance.client;
 FirebaseAnalytics? _analytics;
 String? _appId,_uid;
 bool enabled=false,_configured=false;
 DateTime _checked=DateTime.fromMillisecondsSinceEpoch(0);
 Future<void>? _syncing;
 Future<void> sync(bool consent,{bool force=false}){
   if(_syncing!=null)return _syncing!;
   final task=_sync(consent,force:force);_syncing=task;
   return task.whenComplete(()=>_syncing=null);
 }
 Future<void> _sync(bool consent,{bool force=false}) async{
  enabled=consent;
  if(!consent){await _disable();return;}
  if(!force&&_configured&&DateTime.now().difference(_checked)<const Duration(seconds:60))return;
  _checked=DateTime.now();_configured=false;
  try{
   final uid=_sb.auth.currentUser?.id;
   if(uid==null){await _disable();return;}
   final pref=await _sb.from('google_preferences').select('enabled').eq('user_id',uid).maybeSingle();
   if(pref?['enabled']!=true){await _disable();return;}
   final data=Map<String,dynamic>.from(await _sb.rpc('google_public') as Map);
   final id=data['firebase_app_id'] as String? ?? '';
   if(data['app_enabled']!=true||id.isEmpty){await _disable();return;}
   final p=await SharedPreferences.getInstance();
   final bound=p.getString('firebase_identity_${Config.versionLabel}');
   // Firebase warns that swapping app identity can lose analytics. Lock one identity per app release.
   if((bound!=null&&bound!=id)||(_appId!=null&&_appId!=id)){await _disable();return;}
   if(_analytics==null){
    await Firebase.initializeApp(options:FirebaseOptions(apiKey:data['firebase_api_key'] as String,appId:id,messagingSenderId:data['firebase_sender_id'] as String,projectId:data['firebase_project_id'] as String));
    _analytics=FirebaseAnalytics.instance;_appId=id;await p.setString('firebase_identity_${Config.versionLabel}',id);
   }
   await _analytics!.setConsent(analyticsStorageConsentGranted:true,adStorageConsentGranted:true,adUserDataConsentGranted:true,adPersonalizationSignalsConsentGranted:false);
   await _analytics!.setAnalyticsCollectionEnabled(true);
   _uid=_sb.auth.currentUser?.id;
   final instance=await _analytics!.appInstanceId;
   final session=await _analytics!.getSessionId();
   if(instance!=null&&_uid!=null)await _sb.rpc('set_google_preferences',params:{'p_enabled':true,'p_app_instance_id':instance,'p_firebase_app_id':id,'p_session_id':session});
   _configured=true;
  }catch(_){await _disable();}
 }
 Future<void> _disable() async{
  _configured=false;
  try{await _analytics?.setConsent(analyticsStorageConsentGranted:false,adStorageConsentGranted:false,adUserDataConsentGranted:false,adPersonalizationSignalsConsentGranted:false);await _analytics?.setAnalyticsCollectionEnabled(false);}catch(_){}
 }
 Future<void> track(String event,Map<String,dynamic> properties)async{
  if(!enabled)return;
  await sync(true);if(!_configured||_analytics==null||_uid!=_sb.auth.currentUser?.id)return;
  const names={'AppOpen':'app_open','ScreenView':'screen_view','Login':'login','ViewContent':'select_content','VideoStart':'video_start','VideoProgress':'video_progress','PreviewComplete':'preview_complete','SearchUsed':'search_used','ChannelCreated':'channel_created','ChannelJoined':'join_group','VideoUploaded':'video_uploaded','CloudUploaded':'cloud_uploaded','CloudDeleted':'cloud_deleted','PlanViewed':'plan_viewed','SubscriptionPrompt':'subscription_prompt','CompleteRegistration':'sign_up'};
  final name=names[event];if(name==null)return;
  final safe=<String,Object>{};
  if(['Cloud','Home','Feed','Explore','Channel','Channels','Profile','Premium','Post','Safety'].contains(properties['screen']))safe['screen_name']=properties['screen'] as String;
  if([25,50,75,100].contains(properties['progress']))safe['progress']=properties['progress'] as int;
  for(final key in ['premium','preview']){if(properties[key] is bool)safe[key]=properties[key]==true?1:0;}
  if(event=='Login'||event=='CompleteRegistration')safe['method']='email';
  try{await _analytics!.logEvent(name:name,parameters:safe);}catch(_){}
 }
 Future<void> checkout(Map<String,dynamic> order)async{
  if(!enabled)return;await sync(true);if(!_configured)return;
  try{await _analytics!.logEvent(name:'begin_checkout',parameters:{'currency':'INR','value':(order['amount_inr'] as num).toDouble()});}catch(_){}
 }
 Future<void> revoke()async{enabled=false;await _disable();try{await _analytics?.resetAnalyticsData();}catch(_){} }
}
