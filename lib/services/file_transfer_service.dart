import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/constants.dart';
import '../models/peer_device.dart';
import '../models/transfer_file.dart';

/// 文件级传输服务：HTTP Server + Client（配对 / 收发文件）。
///
/// 配对后双方互报各自 HTTP 端点，因此任一端都能向对端发送文件。
/// HTTP 端口优先 54000，占用时动态回退系统分配端口。
class FileTransferService {
  HttpServer? _server;
  PeerDevice? _self;
  final Map<String, PeerDevice> _paired = <String, PeerDevice>{};
  final StreamController<TransferFile> _receivedController =
      StreamController<TransferFile>.broadcast();

  /// 本机服务端点（含 token）。
  PeerDevice? get self => _self;

  /// 已配对的对端设备列表。
  List<PeerDevice> get pairedPeers => _paired.values.toList();

  /// 接收到的文件流。
  Stream<TransferFile> get receivedFiles => _receivedController.stream;

  /// 启动本地 HTTP 接收服务器，返回本机 PeerDevice（含 token）。
  Future<PeerDevice> startServer({String name = ''}) async {
    if (_server != null && _self != null) return _self!;

    final String ip = await _localIp();
    final String deviceName = name.isNotEmpty ? name : Platform.localHostname;
    final String token = _generateToken();
    final String platform = Platform.isAndroid
        ? 'android'
        : (Platform.isWindows ? 'windows' : 'other');

    HttpServer server;
    try {
      server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        kHttpPortPreferred,
      );
    } on SocketException {
      // 端口占用时动态回退。
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }

    _server = server;
    _self = PeerDevice(
      name: deviceName,
      ip: ip,
      port: server.port,
      token: token,
      platform: platform,
    );
    server.listen(_handleRequest);
    return _self!;
  }

  /// 与对端握手配对，交换双方服务器端点；成功后任一端可互发。
  Future<PeerDevice> pairWith(PeerDevice peer) async {
    final PeerDevice selfDevice = _self ?? await startServer();

    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest request = await client.postUrl(
        Uri.parse('http://${peer.ip}:${peer.port}/pair'),
      );
      request.headers.contentType = ContentType.json;
      request.write(
        jsonEncode(<String, dynamic>{
          'name': selfDevice.name,
          'platform': selfDevice.platform,
          'port': selfDevice.port,
          // 本机 token（供对端后续反向发文件鉴权）。
          'token': selfDevice.token,
          // 对端 token（用于本次配对鉴权）。
          'auth': peer.token,
        }),
      );

      final HttpClientResponse response = await request.close();
      final String body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) {
        throw Exception('配对失败（${response.statusCode}）');
      }

      final Map<String, dynamic> map = jsonDecode(body) as Map<String, dynamic>;
      final PeerDevice registered = PeerDevice(
        name: (map['name'] as String?) ?? peer.name,
        ip: peer.ip,
        port: peer.port,
        token: peer.token,
        platform: (map['platform'] as String?) ?? peer.platform,
      );
      _paired[registered.key] = registered;
      return registered;
    } finally {
      client.close(force: true);
    }
  }

  /// 向已配对对端发送文件，回调进度。
  Future<void> sendFile(
    PeerDevice peer,
    String filePath, {
    void Function(TransferProgress)? onProgress,
  }) async {
    final File file = File(filePath);
    if (!await file.exists()) {
      throw Exception('文件不存在：$filePath');
    }
    final String fileName = p.basename(filePath);
    final int size = await file.length();

    final HttpClient client = HttpClient();
    final RandomAccessFile raf = await file.open();
    try {
      final Uri uri = Uri.parse('http://${peer.ip}:${peer.port}/files').replace(
        queryParameters: <String, String>{'name': fileName, 'size': '$size'},
      );
      final HttpClientRequest request = await client.postUrl(uri);
      request.headers.set('X-Auth-Token', peer.token);
      request.headers.contentType = ContentType.binary;
      request.contentLength = size;

      final Uint8List buffer = Uint8List(64 * 1024);
      int sent = 0;
      while (true) {
        final int read = await raf.readInto(buffer);
        if (read <= 0) break;
        request.add(buffer.sublist(0, read));
        sent += read;
        onProgress?.call(
          TransferProgress(fileName: fileName, sent: sent, total: size),
        );
      }

      final HttpClientResponse response = await request.close();
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>();
        throw Exception('发送失败（${response.statusCode}）');
      }
      await response.drain<void>();
    } finally {
      await raf.close();
      client.close(force: true);
    }
  }

  /// 停止服务器并释放资源。
  Future<void> stopServer() async {
    await _server?.close(force: true);
    _server = null;
    _self = null;
    _paired.clear();
    await _receivedController.close();
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      if (request.method == 'GET' && request.uri.path == '/ping') {
        await _sendJson(request, <String, dynamic>{
          'ok': true,
          'name': _self?.name ?? '',
        });
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/pair') {
        await _handlePair(request);
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/files') {
        await _handleFiles(request);
        return;
      }

      await _sendStatus(request, HttpStatus.notFound);
    } catch (_) {
      try {
        await _sendStatus(request, HttpStatus.internalServerError);
      } catch (_) {
        // 响应可能已关闭，忽略。
      }
    }
  }

  Future<void> _handlePair(HttpRequest request) async {
    final String body = await utf8.decoder.bind(request).join();
    final Map<String, dynamic> map = jsonDecode(body) as Map<String, dynamic>;

    final String auth = (map['auth'] as String?) ?? '';
    if (_self == null || auth != _self!.token) {
      await _sendStatus(request, HttpStatus.unauthorized);
      return;
    }

    final int port = (map['port'] as num?)?.toInt() ?? -1;
    final String remoteIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (port <= 0 || remoteIp.isEmpty) {
      await _sendStatus(request, HttpStatus.badRequest);
      return;
    }

    final PeerDevice peer = PeerDevice(
      name: (map['name'] as String?) ?? '对端设备',
      ip: remoteIp,
      port: port,
      token: (map['token'] as String?) ?? '',
      platform: (map['platform'] as String?) ?? 'unknown',
    );
    _paired[peer.key] = peer;

    await _sendJson(request, <String, dynamic>{
      'ok': true,
      'name': _self!.name,
      'platform': _self!.platform,
      'port': _self!.port,
      'token': _self!.token,
    });
  }

  Future<void> _handleFiles(HttpRequest request) async {
    final String auth = request.headers.value('X-Auth-Token') ?? '';
    if (_self == null || auth != _self!.token) {
      await _sendStatus(request, HttpStatus.unauthorized);
      return;
    }

    final String rawName =
        request.uri.queryParameters['name'] ?? 'received_file';
    final int declaredSize =
        int.tryParse(request.uri.queryParameters['size'] ?? '') ?? 0;
    final String safeName = _safeFileName(rawName);

    final Directory dir = await _receivedDir();
    final String path = p.join(dir.path, safeName);
    final IOSink sink = File(path).openWrite();
    int received = 0;
    try {
      await for (final List<int> chunk in request) {
        sink.add(chunk);
        received += chunk.length;
      }
    } finally {
      await sink.close();
    }

    _receivedController.add(
      TransferFile(
        name: safeName,
        size: received > 0 ? received : declaredSize,
        path: path,
      ),
    );
    await _sendStatus(request, HttpStatus.ok);
  }

  Future<Directory> _receivedDir() async {
    final Directory base = await getApplicationDocumentsDirectory();
    final Directory dir = Directory(p.join(base.path, 'received'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safeFileName(String name) {
    String base = p.basename(name).trim();
    if (base.isEmpty) base = 'received_file';
    base = base.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    return base;
  }

  Future<String> _localIp() async {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final NetworkInterface iface in interfaces) {
      for (final InternetAddress addr in iface.addresses) {
        final String s = addr.address;
        if (s.startsWith('192.168.') ||
            s.startsWith('10.') ||
            s.startsWith('172.')) {
          return s;
        }
      }
    }
    for (final NetworkInterface iface in interfaces) {
      for (final InternetAddress addr in iface.addresses) {
        if (!addr.isLoopback) return addr.address;
      }
    }
    return '127.0.0.1';
  }

  String _generateToken() {
    const String chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final Random random = Random.secure();
    final StringBuffer buffer = StringBuffer();
    for (int i = 0; i < kTokenLength; i++) {
      buffer.write(chars[random.nextInt(chars.length)]);
    }
    return buffer.toString();
  }

  Future<void> _sendJson(HttpRequest request, Map<String, dynamic> json) async {
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(json));
    await request.response.close();
  }

  Future<void> _sendStatus(HttpRequest request, int status) async {
    request.response.statusCode = status;
    await request.response.close();
  }
}
