import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/platform.dart';
import '../models/peer_device.dart';
import '../providers/transfer_provider.dart';
import '../widgets/file_list_tile.dart';
import '../widgets/qr_code_card.dart';
import '../widgets/status_badge.dart';

/// 数据传输页（右侧 tab）：局域网扫码/发现，双向传输文件。
///
/// 由原「设置 / 数据传输」混合页拆出，设置页只保留 OCR 引擎配置。
class TransferPage extends StatelessWidget {
  const TransferPage({super.key});

  @override
  Widget build(BuildContext context) {
    final TransferProvider provider = context.watch<TransferProvider>();

    return Scaffold(
      appBar: AppBar(title: const Text('数据传输')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: appSoftSurface(context),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.wifi_tethering, color: kPrimaryColor, size: 20),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '在同一局域网内启动服务后，桌面端展示二维码、手机端扫码连接；'
                    '也可自动发现周围设备。连接后双向发送文件。',
                    style: TextStyle(fontSize: 12, color: kPrimaryColor),
                  ),
                ),
              ],
            ),
          ),
          if (!provider.isServerRunning) ...<Widget>[
            const SizedBox(height: 32),
            const Icon(Icons.wifi_off, size: 56, color: kNeutralGrey),
            const SizedBox(height: 12),
            const Center(child: Text('数据传输未启动')),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: provider.isLoading
                  ? null
                  : () => context.read<TransferProvider>().init(),
              icon: const Icon(Icons.power_settings_new),
              label: const Text('启动传输服务'),
            ),
          ] else ...<Widget>[
            const SizedBox(height: 16),
            _buildSelfCard(provider),
            const SizedBox(height: 16),
            if (isDesktop) ...<Widget>[
              Center(
                child: provider.qrContent == null
                    ? const SizedBox.shrink()
                    : QrCodeCard(content: provider.qrContent!),
              ),
              const SizedBox(height: 12),
              const Center(
                child: Text(
                  '用手机端「扫描二维码连接」扫码配对',
                  style: TextStyle(fontSize: 12, color: kNeutralGrey),
                ),
              ),
            ] else ...<Widget>[
              FilledButton.icon(
                onPressed: () => _scanQr(context),
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('扫描二维码连接'),
              ),
              const SizedBox(height: 16),
              Text('发现的设备', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              if (provider.discovered.isEmpty)
                const Text(
                  '暂未发现设备，可尝试扫码连接',
                  style: TextStyle(color: kNeutralGrey),
                )
              else
                for (final PeerDevice peer in provider.discovered)
                  ListTile(
                    leading: const Icon(Icons.devices, color: kPrimaryColor),
                    title: Text(peer.name),
                    subtitle: Text('${peer.endpoint} · ${peer.platform}'),
                    trailing: FilledButton(
                      onPressed: provider.isLoading
                          ? null
                          : () => context
                                .read<TransferProvider>()
                                .connectToDevice(peer),
                      child: const Text('连接'),
                    ),
                  ),
            ],
            const SizedBox(height: 16),
            if (provider.isConnected) ...<Widget>[
              Card(
                child: ListTile(
                  leading: const StatusBadge(
                    label: '已配对',
                    color: kSuccessColor,
                    icon: Icons.check_circle,
                  ),
                  title: Text(provider.connectedPeer!.name),
                  subtitle: Text(provider.connectedPeer!.endpoint),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: provider.isLoading
                    ? null
                    : () => context.read<TransferProvider>().pickAndSendFile(),
                icon: const Icon(Icons.send),
                label: Text(provider.isLoading ? '处理中…' : '选择文件发送'),
              ),
            ],
            if (provider.progress != null) ...<Widget>[
              const SizedBox(height: 16),
              FileListTile(
                title: provider.progress!.fileName,
                progress: provider.progress,
              ),
            ],
            if (provider.receivedFiles.isNotEmpty) ...<Widget>[
              const SizedBox(height: 16),
              Text('已接收文件', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              for (final file in provider.receivedFiles)
                FileListTile(title: file.name, subtitle: file.sizeLabel),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () => context.read<TransferProvider>().stop(),
              icon: const Icon(Icons.stop),
              label: const Text('停止传输服务'),
            ),
          ],
          if (provider.error != null) ...<Widget>[
            const SizedBox(height: 16),
            _Banner(
              color: kErrorColor,
              icon: Icons.error_outline,
              text: provider.error!,
              onClose: () => context.read<TransferProvider>().clearError(),
            ),
          ],
          if (provider.lastMessage != null &&
              provider.error == null) ...<Widget>[
            const SizedBox(height: 8),
            _Banner(
              color: kSuccessColor,
              icon: Icons.check_circle_outline,
              text: provider.lastMessage!,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSelfCard(TransferProvider provider) {
    final PeerDevice? self = provider.self;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '本机信息',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text('名称：${self?.name ?? '-'}'),
            Text('地址：${self?.endpoint ?? '-'}'),
            Text('平台：${self?.platform ?? '-'}'),
            Text('Token：${self?.token ?? '-'}'),
          ],
        ),
      ),
    );
  }

  Future<void> _scanQr(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('扫描二维码'),
          content: SizedBox(
            width: 300,
            height: 300,
            child: MobileScanner(
              onDetect: (BarcodeCapture capture) {
                final List<Barcode> barcodes = capture.barcodes;
                if (barcodes.isEmpty) return;
                final String? raw = barcodes.first.rawValue;
                if (raw == null || raw.isEmpty) return;
                Navigator.of(dialogContext).pop();
                context.read<TransferProvider>().connectViaQr(raw);
              },
              onDetectError: (Object error, StackTrace stackTrace) {
                // 相机权限或设备错误，静默忽略；用户可关闭后重试。
              },
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
          ],
        );
      },
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.icon,
    required this.text,
    this.onClose,
  });

  final Color color;
  final IconData icon;
  final String text;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: color, fontSize: 13)),
          ),
          if (onClose != null)
            GestureDetector(
              onTap: onClose,
              child: Icon(Icons.close, color: color, size: 18),
            ),
        ],
      ),
    );
  }
}
