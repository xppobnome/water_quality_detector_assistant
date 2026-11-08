import '../core/constants.dart';
import '../models/peer_device.dart';

/// 二维码内容构造 / 解析。
class QrService {
  /// 构造二维码内容：`WQA|1.0|{ip}:{port}|{token}`。
  String buildQrContent(PeerDevice self) {
    return '$kServiceTag|$kProtocolVersion|${self.ip}:${self.port}|${self.token}';
  }

  /// 解析扫码结果；非法 / 版本不符返回 null。
  PeerDevice? parseQrContent(String content) {
    final String trimmed = content.trim();
    final List<String> parts = trimmed.split('|');
    if (parts.length != 4) return null;
    if (parts[0] != kServiceTag) return null;
    if (parts[1] != kProtocolVersion) return null;

    final List<String> addr = parts[2].split(':');
    if (addr.length != 2) return null;
    final String ip = addr[0].trim();
    final int? port = int.tryParse(addr[1].trim());
    if (ip.isEmpty || port == null || port <= 0 || port > 65535) return null;

    final String token = parts[3].trim();
    if (token.isEmpty) return null;

    return PeerDevice(
      name: '扫码设备($ip)',
      ip: ip,
      port: port,
      token: token,
      platform: 'unknown',
    );
  }
}
