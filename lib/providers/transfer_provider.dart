import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../core/platform.dart';
import '../models/peer_device.dart';
import '../models/transfer_file.dart';
import '../services/discovery_service.dart';
import '../services/file_transfer_service.dart';
import '../services/qr_service.dart';

/// 数据传输状态（HTTP 服务 + UDP 发现 + 扫码配对）。
class TransferProvider extends ChangeNotifier {
  TransferProvider({
    FileTransferService? transfer,
    DiscoveryService? discovery,
    QrService? qr,
  }) : _transfer = transfer ?? FileTransferService(),
       _discovery = discovery ?? DiscoveryService(),
       _qr = qr ?? QrService();

  final FileTransferService _transfer;
  final DiscoveryService _discovery;
  final QrService _qr;

  PeerDevice? self;
  final List<PeerDevice> discovered = <PeerDevice>[];
  PeerDevice? connectedPeer;
  final List<TransferFile> receivedFiles = <TransferFile>[];
  TransferProgress? progress;
  bool isLoading = false;
  bool isServerRunning = false;
  String? error;
  String? lastMessage;

  StreamSubscription<PeerDevice>? _discoverySub;
  StreamSubscription<TransferFile>? _receivedSub;

  bool get isConnected => connectedPeer != null;

  /// 二维码内容（桌面端展示）。
  String? get qrContent {
    final PeerDevice? s = self;
    return s == null ? null : _qr.buildQrContent(s);
  }

  /// 启动本机服务并订阅发现/接收流；桌面端广播，手机端监听。
  Future<void> init() async {
    _discoverySub = _discovery.discoveredPeers.listen(_onPeer);
    _receivedSub = _transfer.receivedFiles.listen(_onFile);

    try {
      self = await _transfer.startServer();
      isServerRunning = true;
      if (isDesktop) {
        _discovery.startBroadcasting(self!);
      } else {
        _discovery.startListening();
      }
      lastMessage = '传输服务已启动：${self!.endpoint}';
    } catch (e) {
      error = '启动传输服务失败：$e';
    }
    notifyListeners();
  }

  Future<void> connectViaQr(String content) async {
    final PeerDevice? peer = _qr.parseQrContent(content);
    if (peer == null) {
      error = '二维码内容无效';
      notifyListeners();
      return;
    }
    await connectToDevice(peer);
  }

  Future<void> connectToDevice(PeerDevice peer) async {
    isLoading = true;
    error = null;
    notifyListeners();
    try {
      connectedPeer = await _transfer.pairWith(peer);
      lastMessage = '已与 ${connectedPeer!.name}（${connectedPeer!.endpoint}）配对';
    } catch (e) {
      error = '配对失败：$e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> pickAndSendFile() async {
    final PeerDevice? peer = connectedPeer;
    if (peer == null) {
      error = '请先配对设备';
      notifyListeners();
      return;
    }
    try {
      final PlatformFile? file = await FilePicker.pickFile(type: FileType.any);
      if (file == null) return;
      final String? path = file.path;
      if (path == null) {
        error = '无法读取所选文件路径';
        notifyListeners();
        return;
      }
      await sendFile(peer, path);
    } catch (e) {
      error = '选择文件失败：$e';
      notifyListeners();
    }
  }

  Future<void> sendFile(PeerDevice peer, String path) async {
    isLoading = true;
    error = null;
    progress = null;
    notifyListeners();
    try {
      await _transfer.sendFile(
        peer,
        path,
        onProgress: (TransferProgress value) {
          progress = value;
          notifyListeners();
        },
      );
      lastMessage = '发送成功：${p.basename(path)}';
    } catch (e) {
      error = '发送失败：$e';
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    await _discoverySub?.cancel();
    await _receivedSub?.cancel();
    _discoverySub = null;
    _receivedSub = null;
    _discovery.stop();
    await _transfer.stopServer();
    isServerRunning = false;
    self = null;
    connectedPeer = null;
    discovered.clear();
    notifyListeners();
  }

  void clearError() {
    error = null;
    notifyListeners();
  }

  void _onPeer(PeerDevice peer) {
    final int index = discovered.indexWhere((d) => d.key == peer.key);
    if (index >= 0) {
      discovered[index] = peer;
    } else {
      discovered.add(peer);
    }
    notifyListeners();
  }

  void _onFile(TransferFile file) {
    receivedFiles.insert(0, file);
    lastMessage = '已接收文件：${file.name}';
    notifyListeners();
  }

  @override
  void dispose() {
    _discoverySub?.cancel();
    _receivedSub?.cancel();
    _discovery.stop();
    super.dispose();
  }
}
