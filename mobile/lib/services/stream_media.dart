import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_state.dart';

final _virtualKey = RegExp(r'^[0-9a-f-]{36}/bunny/[0-9a-f-]{36}$');
bool isStreamKey(String key) => _virtualKey.hasMatch(key);

Future<Map<String, String>> signMedia(Iterable<String> keys, {required String kind}) async {
  // Flixvault thumbnails already arrive as public https links: use them as they are.
  final result = <String, String>{for (final key in keys) if (key.startsWith('https://')) key: key};
  keys = keys.where((key) => !key.startsWith('https://'));
  final ordinary = keys.where((key) => !isStreamKey(key)).toSet().toList();
  final stream = keys.where(isStreamKey).toSet().toList();
  if (ordinary.isNotEmpty) {
    final links = await sb.storage.from('media').createSignedUrls(ordinary, 3600);
    for (final link in links) {
      final path = link.path;
      if (link.signedUrl.isNotEmpty) result[path] = link.signedUrl;
    }
  }
  for (var offset = 0; offset < stream.length; offset += 80) {
    final response = await sb.functions.invoke('bunny-stream', body: {
      'action': 'urls', 'kind': kind, 'keys': stream.skip(offset).take(80).toList(),
    });
    if (response.data is Map && response.data['urls'] is Map) {
      result.addAll(Map<String, String>.from(response.data['urls'] as Map));
    }
  }
  return result;
}

Future<String> uploadVideo({
  required String legacyPath, required File file, required String contentType,
  required String title, required String purpose, void Function(int)? progress,
}) async {
  final response = await sb.functions.invoke('bunny-stream', body: {
    'action': 'create', 'channel_id': legacyPath.split('/').first,
    'purpose': purpose, 'title': title, 'content_type': contentType,
  });
  final grant = Map<String, dynamic>.from(response.data as Map);
  if (grant['configured'] == false) {
    await sb.storage.from('media').upload(legacyPath, file, fileOptions: FileOptions(contentType: contentType));
    return legacyPath;
  }
  final auth = Map<String, String>.from(grant['headers'] as Map);
  final endpoint = Uri.https('video.bunnycdn.com', '/tusupload');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  final size = await file.length();
  final input = await file.open();
  Future<HttpClientRequest> request(String method, Uri url) async {
    final req = await client.openUrl(method, url);
    req.followRedirects = false;
    req.headers.set('Tus-Resumable', '1.0.0');
    auth.forEach(req.headers.set);
    return req;
  }
  try {
    final create = await request('POST', endpoint);
    create.contentLength = 0;
    create.headers.set('Upload-Length', size);
    create.headers.set('Upload-Metadata',
      'filetype ${base64Encode(utf8.encode(contentType))},title ${base64Encode(utf8.encode(title))}');
    final created = await create.close();
    final location = created.headers.value('location');
    await created.drain<void>();
    if (created.statusCode != 201 || location == null) throw const HttpException('Could not start video upload');
    final upload = endpoint.resolve(location);
    if (upload.scheme != 'https' || upload.host != endpoint.host || upload.port != endpoint.port) {
      throw const HttpException('Invalid upload destination');
    }
    const chunkBytes = 32 * 1024 * 1024;
    var offset = 0;
    var retries = 0;
    while (offset < size) {
      try {
        await input.setPosition(offset);
        final bytes = await input.read(min(chunkBytes, size - offset));
        if (bytes.isEmpty) throw const HttpException('Video file is incomplete');
        final patch = await request('PATCH', upload);
        patch.contentLength = bytes.length;
        patch.headers.set('content-type', 'application/offset+octet-stream');
        patch.headers.set('Upload-Offset', offset);
        patch.add(bytes);
        final written = await patch.close().timeout(const Duration(minutes: 3));
        final saved = int.tryParse(written.headers.value('Upload-Offset') ?? '');
        await written.drain<void>();
        if (written.statusCode != 204 || saved != offset + bytes.length) {
          throw const HttpException('Video upload needs to resume');
        }
        offset = saved!;
        retries = 0;
        progress?.call((100 * offset / size).round());
      } catch (_) {
        if (++retries > 3) rethrow;
        await Future<void>.delayed(Duration(seconds: retries * 2));
        final head = await request('HEAD', upload);
        final current = await head.close().timeout(const Duration(seconds: 20));
        final saved = int.tryParse(current.headers.value('Upload-Offset') ?? '');
        await current.drain<void>();
        if (current.statusCode != 200 && current.statusCode != 204 ||
            saved == null || saved < offset || saved > size) rethrow;
        offset = saved;
      }
    }
    return grant['key'] as String;
  } finally {
    await input.close();
    client.close(force: true);
  }
}
