import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../config.dart';

/// Capture once, retain until acknowledged, and link the same install after account changes.
class InstallAttribution {
  static const channel=MethodChannel('app/install-referrer');
  static Future<void> record({bool forceLink=false}) async {
    final sb=Supabase.instance.client, uid=Supabase.instance.client.auth.currentUser?.id;
    if(uid==null)return;
    final p=await SharedPreferences.getInstance();
    final id=p.getString('install_id')??const Uuid().v4();
    final secret=p.getString('install_secret')??const Uuid().v4();
    await p.setString('install_id',id);await p.setString('install_secret',secret);
    if(!forceLink&&p.getString('attribution_v2_user')==uid)return;
    Map<String,dynamic> capture;
    final cached=p.getString('install_referrer_v2');
    if(cached!=null){capture=Map<String,dynamic>.from(jsonDecode(cached) as Map);}
    else {
      try {capture=Map<String,dynamic>.from(await channel.invokeMapMethod<String,dynamic>('get')??{});}
      catch(_){capture={'status':'not_available','referrer':''};}
      if(capture['status']=='non_play'){
        capture={'status':Config.apkReferrer.isEmpty?'direct':'apk_define','referrer':Config.apkReferrer};
      }
      capture.putIfAbsent('install_ts',()=>DateTime.now().millisecondsSinceEpoch~/1000);
      await p.setString('install_referrer_v2',jsonEncode(capture));
    }
    await sb.rpc('record_install_attribution',params:{'p_install_id':id,'p_install_secret':secret,
      'p_referrer_status':capture['status']??'not_available','p_raw_referrer':capture['referrer']??'',
      'p_click_ts':capture['click_ts'],'p_install_ts':capture['install_ts']});
    await p.setString('attribution_v2_user',uid);
  }
}
