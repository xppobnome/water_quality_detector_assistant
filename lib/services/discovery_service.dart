import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/constants.dart';
import '../models/peer_device.dart';

/// UDP 广播发现服务。
///
/// 桌面端周期广播本机信息，手机端监听并列出可用设备；
/// 扫码连接作为不可达网络的兜底。
class DiscoveryService {
  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  PeerDevice? _self;

  final StreamController<PeerDevice> _controller =
      StreamController<PeerDevice>.broadcast();

  /// 发现的设备流。
  Stream<PeerDevice> get discoveredPeers => _controller.stream;

  /// 周期广播本机信息（含 ip:port + token）。
  void startBroadcasting(PeerDevice self) {
    _self = self;
    _ensureSocket();
    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _broadcast(),
    );
  }

  /// 监听广播。
  void startListening() {
    _ensureSocket();
  }

  /// 停止广播/监听并释放资源。
  void stop() {
    _broadcastTimer?.cancel();
    _broadcastTimer = null;
    _socket?.close();
    _socket = null;
    _controller.close();
  }

  Future<void> _ensureSocket() async {
    if (_socket != null) return;
    try {
      final RawDatagramSocket socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kUdpDiscoveryPort,
      );
      socket.broadcastEnabled = true;
      socket.listen(_onEvent);
      _socket = socket;
    } catch (_) {
      // 端口被占用时无法监听，扫码连接仍可作为兜底。
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final Datagram? datagram = _socket?.receive();
    if (datagram == null) return;
    _handle(datagram.data);
  }

  void _handle(List<int> data) {
    try {
      final Map<String, dynamic> map =
          jsonDecode(utf8.decode(data)) as Map<String, dynamic>;
      if (map['type'] != 'wqa_hello') return;

      final String ip = (map['ip'] as String?) ?? '';
      if (ip.isEmpty) return;
      // 跳过本机广播。
      if (_self != null && ip == _self!.ip) return;

      final int port = (map['port'] as num?)?.toInt() ?? -1;
      final String token = (map['token'] as String?) ?? '';
      if (port <= 0 || token.isEmpty) return;

      _controller.add(
        PeerDevice(
          name: (map['name'] as String?) ?? '未知设备',
          ip: ip,
          port: port,
          token: token,
          platform: (map['platform'] as String?) ?? 'unknown',
        ),
      );
    } catch (_) {
      // 忽略无法解析的数据包。
    }
  }

  void _broadcast() {
    final RawDatagramSocket? socket = _socket;
    final PeerDevice? self = _self;
    if (socket == null || self == null) return;

    final String payload = jsonEncode(<String, dynamic>{
      'type': 'wqa_hello',
      'name': self.name,
      'ip': self.ip,
      'port': self.port,
      'token': self.token,
      'platform': self.platform,
    });
    try {
      socket.send(
        utf8.encode(payload),
        InternetAddress('255.255.255.255'),
        kUdpDiscoveryPort,
      );
    } catch (_) {
      // 广播失败忽略，下一周期重试。
    }
  }
}
