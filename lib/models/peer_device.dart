/// 对端设备（发现/配对）。
class PeerDevice {
  PeerDevice({
    required this.name,
    required this.ip,
    required this.port,
    required this.token,
    required this.platform,
  });

  /// 设备名。
  final String name;

  /// IPv4 地址。
  final String ip;

  /// HTTP 服务器端口。
  final int port;

  /// 配对鉴权 token。
  final String token;

  /// 平台：android / windows / unknown。
  final String platform;

  /// 显示用地址。
  String get endpoint => '$ip:$port';

  /// 设备唯一键（用于列表去重）。
  String get key => '$ip:$port';
}
