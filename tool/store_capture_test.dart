import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:puffle/screens/home_shell.dart';
import 'package:puffle/services/app_scope.dart';
import 'package:puffle/services/app_state.dart';
import 'package:puffle/models/status.dart';
import 'package:puffle/theme.dart';

class ImageHeaders extends Fake implements HttpHeaders {
  @override void add(String name,Object value,{bool preserveHeaderCase=false}) {}
}
class ImageRequest extends Fake implements HttpClientRequest {
  ImageRequest(this.bytes);
  final Uint8List bytes;
  @override HttpHeaders get headers => ImageHeaders();
  @override Future<HttpClientResponse> close() async => ImageResponse(bytes);
}
class ImageResponse extends Stream<List<int>> implements HttpClientResponse {
  ImageResponse(this.bytes); final Uint8List bytes;
  @override int get statusCode=>200;
  @override int get contentLength=>bytes.length;
  @override HttpClientResponseCompressionState get compressionState=>HttpClientResponseCompressionState.notCompressed;
  @override StreamSubscription<List<int>> listen(void Function(List<int>)? onData,{Function? onError,void Function()? onDone,bool? cancelOnError})=>Stream<List<int>>.value(bytes).listen(onData,onError:onError,onDone:onDone,cancelOnError:cancelOnError);
  @override dynamic noSuchMethod(Invocation invocation)=>super.noSuchMethod(invocation);
}
class ImageClient extends Fake implements HttpClient {
  ImageClient(this.images); final List<Uint8List> images;
  @override set autoUncompress(bool value) {}
  @override Future<HttpClientRequest> getUrl(Uri url) async=>ImageRequest(images[int.tryParse(url.pathSegments.last.replaceAll(RegExp(r'[^0-9]'),''))??0]);
}
class ImageOverride extends HttpOverrides {
  ImageOverride(this.images); final List<Uint8List> images;
  @override HttpClient createHttpClient(SecurityContext? context)=>ImageClient(images);
}
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('capture real Puffle screens with sample content', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final font=FontLoader('Inter')..addFont(Future.value(ByteData.sublistView(File('store-capture/Inter.ttf').readAsBytesSync())));
    await font.load();
    final icons=FontLoader('MaterialIcons')..addFont(Future.value(ByteData.sublistView(File('store-capture/MaterialIcons.otf').readAsBytesSync())));
    await icons.load();
    final images=List.generate(6,(i)=>File('store-capture/poster_$i.png').readAsBytesSync());
    HttpOverrides.global=ImageOverride(images);
    final names=['Creative studio','Learn every day','Weekend trails'];
    final titles=['Small ideas, big possibilities','Learn something new today','Find your next adventure','A little daily inspiration','Discover a different perspective','Make time for what you love'];
    final channels=List.generate(3,(i)=><String,dynamic>{'id':'ch$i','name':names[i],'description':'Ideas and videos to inspire your day.','review_status':'approved','created_by':'creator$i','members_count':12+i});
    final posts=List.generate(6,(i)=><String,dynamic>{'id':'post$i','title':titles[i],'channel_id':'ch${i%3}','created_at':'2026-11-14T10:00:00Z','channels':{'name':names[i%3],'category':'Lifestyle'},'post_items':[{'thumbnail_key':'thumb$i','position':0,'is_premium':i%3==0,'duration_s':120+i*31}]});
    final raw=<String,dynamic>{'user_id':'sample-user','is_guest':false,'is_premium':true,'can_play_premium':true,'source':'organic','has_ads_access':false,'access_status':'pending','free_mode':false,'plans_visible':false,'payments_available':false,'quota_bytes':2199023255552,'used_bytes':234881024,'plan_name':'Gold','plan_ends_at':'2027-01-01T00:00:00Z'};
    await Supabase.initialize(url:'https://assets.puffle.test',anonKey:'sample-public-key',authOptions:const FlutterAuthClientOptions(detectSessionInUri:false,autoRefreshToken:false),httpClient:MockClient((request) async {
      dynamic data=[];
      final path=request.url.path;
      print('CAPTURE request: $path');
      if(path.endsWith('/channels')) data=channels;
      else if(path.endsWith('/posts')) data=posts;
      else if(path.endsWith('/cloud_files')) data=[{'id':'f1','name':'Travel photos.zip','size_bytes':104857600,'mime':'application/zip','created_at':'2026-11-14T10:00:00Z'},{'id':'f2','name':'Project notes.pdf','size_bytes':2097152,'mime':'application/pdf','created_at':'2026-11-14T10:00:00Z'}];
      else if(path.contains('/object/sign/')) {
        final body=jsonDecode(request.body) as Map;
        data=[for(final key in body['paths'] as List) {'path':key,'signedURL':'/object/sign/media/$key','error':null}];
      } else if(path.endsWith('/rpc/my_status')) data=raw;
      return http.Response(jsonEncode(data),200,headers:{'content-type':'application/json'});
    }));
    final check = await tester.runAsync(() => Supabase.instance.client.from('channels').select('id,name'));
    print('CAPTURE channel result: $check');
    expect(check,hasLength(3));
    final app=AppState()..status=AppStatus(raw)..loaded=true;
    tester.view.physicalSize=const Size(1170,2532); tester.view.devicePixelRatio=3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(RepaintBoundary(key:const Key('capture'),child:AppScope(state:app,child:MaterialApp(debugShowCheckedModeBanner:false,theme:buildTheme(),home:const HomeShell()))));
    await tester.pumpAndSettle();
    for (var attempt=0; attempt<30 && find.text(titles[0]).evaluate().isEmpty; attempt++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:100)));
      await tester.pumpAndSettle();
    }
    expect(find.text(titles[0]),findsWidgets,reason:'Sample posts must load before capturing listing screenshots.');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds:200)));
    await tester.pumpAndSettle();
    final out=Directory('../play-console-assets/phone-screenshots')..createSync(recursive:true);
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        final boundary=tester.renderObject<RenderRepaintBoundary>(find.byKey(const Key('capture')));
        final image=await boundary.toImage(pixelRatio:3);
        final bytes=await image.toByteData(format:ui.ImageByteFormat.png);
        File('${out.path}/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await capture('01_home');
    await tester.tap(find.text('Explore').last); await capture('02_explore');
    await tester.tap(find.text('Cloud').last); await capture('03_cloud');
    await tester.tap(find.text('Profile').last); await capture('04_profile');
    expect(tester.takeException(),isNull);
    await tester.pumpWidget(const SizedBox());
    app.dispose();
    HttpOverrides.global=null;
  });
}
