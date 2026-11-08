import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../core/platform.dart';
import '../services/ocr_log.dart';
import '../services/ocr_service.dart';
import '../services/storage_service.dart';

/// 设置页：仅 OCR 引擎配置，由「工具」页右上角齿轮进入。
///
/// 数据传输已拆到右侧独立 tab；本页不再包含传输 UI。
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _platformCard(),
          const SizedBox(height: 16),
          if (isDesktop) ...<Widget>[
            const _EngineDiagnosisCard(),
            const SizedBox(height: 16),
          ],
          const _OcrConfigCard(),
          const SizedBox(height: 16),
          const _AboutCard(),
        ],
      ),
    );
  }

  Widget _platformCard() {
    final String platform = isWindows
        ? 'Windows 桌面端'
        : (isMobile ? 'Android 移动端' : '桌面端');
    final String strategy = isDesktop
        ? 'Windows 使用「Python 进程启动并加载 OCR 模型」的纯本地方案：'
              'Flutter 通过 Process.start 拉起随应用分发的 ocr_engine.exe，'
              'PaddleOCR 模型常驻、离线识别，无需安装 Python 或配置路径。'
        : 'Android 使用 Google ML Kit 中文文本识别（google_mlkit_text_recognition）：'
              '模型随 APK 打包、端侧离线推理；无需后端服务、API Key 或联网，'
              '拍照后走四角裁剪再直接识别。';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(
              isDesktop ? Icons.desktop_windows_outlined : Icons.phone_android,
              color: kPrimaryColor,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '当前平台：$platform',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  Text(strategy, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OcrConfigCard extends StatefulWidget {
  const _OcrConfigCard();

  @override
  State<_OcrConfigCard> createState() => _OcrConfigCardState();
}

class _OcrConfigCardState extends State<_OcrConfigCard> {
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _keyController = TextEditingController();
  final TextEditingController _pathController = TextEditingController();
  String _engine = 'local';
  bool _saved = false;

  @override
  void initState() {
    super.initState();
    final StorageService storage = context.read<StorageService>();
    _engine = storage.ocrEngine;
    _urlController.text = storage.ocrApiBaseUrl ?? '';
    _keyController.text = storage.ocrApiKey ?? '';
    _pathController.text = storage.ocrEnginePath ?? '';
  }

  @override
  void dispose() {
    _urlController.dispose();
    _keyController.dispose();
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final StorageService storage = context.read<StorageService>();
    final bool mobile = isMobile;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'OCR 引擎配置',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 4),
            Text(
              mobile
                  ? '端侧引擎：Google ML Kit 中文模型，随 APK 打包、离线识别，无需任何配置；'
                        '云端：可配置的 OCR 服务地址（可选）。'
                  : '本地：随应用分发的 PaddleOCR 引擎（离线、纯本地）；'
                        '云端：可配置的 OCR 服务地址。',
              style: const TextStyle(fontSize: 12, color: kNeutralGrey),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'local',
                  label: Text(mobile ? '端侧引擎' : '本地引擎'),
                ),
                const ButtonSegment<String>(
                  value: 'cloud',
                  label: Text('云端服务'),
                ),
              ],
              selected: <String>{_engine},
              onSelectionChanged: (Set<String> s) =>
                  setState(() => _engine = s.first),
            ),
            const SizedBox(height: 12),
            if (_engine == 'local') ...<Widget>[
              if (mobile)
                const _MlKitInfoCard()
              else ...<Widget>[
                TextField(
                  controller: _pathController,
                  decoration: const InputDecoration(
                    labelText: '本地引擎路径（可选）',
                    hintText: '留空则自动查找随应用分发的 ocr_engine 目录',
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '运行项目 python/build_engine.bat 可一键打包；'
                  '产物由 CMake 自动拷到应用目录，通常无需手动指定。',
                  style: TextStyle(fontSize: 12, color: kNeutralGrey),
                ),
              ],
            ] else ...<Widget>[
              TextField(
                controller: _urlController,
                decoration: const InputDecoration(
                  labelText: 'OCR 服务地址',
                  hintText: 'https://your-ocr-service/recognize',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _keyController,
                decoration: const InputDecoration(
                  labelText: 'API Key（可选）',
                  hintText: '留空则不加 Authorization 头',
                ),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                FilledButton.icon(
                  onPressed: () async {
                    await storage.setOcrEngine(_engine);
                    await storage.setOcrEnginePath(_pathController.text.trim());
                    await storage.setOcrApiBaseUrl(_urlController.text.trim());
                    await storage.setOcrApiKey(_keyController.text.trim());
                    if (!context.mounted) return;
                    setState(() => _saved = true);
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('OCR 配置已保存，重新进入工具后生效')),
                    );
                  },
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存'),
                ),
                if (_saved) ...<Widget>[
                  const SizedBox(width: 12),
                  const Icon(
                    Icons.check_circle,
                    color: kSuccessColor,
                    size: 20,
                  ),
                  const SizedBox(width: 4),
                  const Text('已保存', style: TextStyle(color: kSuccessColor)),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 移动端端侧 OCR 说明卡：明确「零配置、离线可用」。
class _MlKitInfoCard extends StatelessWidget {
  const _MlKitInfoCard();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: kPrimaryLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.check_circle_outline, color: kPrimaryColor, size: 18),
              SizedBox(width: 8),
              Text(
                '端侧离线 OCR 已内置',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: kPrimaryColor,
                ),
              ),
            ],
          ),
          SizedBox(height: 6),
          Text(
            'google_mlkit_text_recognition · 中文模型\n'
            '无需安装 Python、无需搭建服务、无需 API Key、无需联网。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

/// 桌面端「引擎诊断」：显示实际解析到的引擎路径与文件是否存在，
/// 并可生成一张测试 PNG 走一次 initEngine + recognizeRaw，把返回文本 /
/// [OcrService.lastError] 直接展示出来，避免「识别不了但看不到原因」。
class _EngineDiagnosisCard extends StatefulWidget {
  const _EngineDiagnosisCard();

  @override
  State<_EngineDiagnosisCard> createState() => _EngineDiagnosisCardState();
}

class _EngineDiagnosisCardState extends State<_EngineDiagnosisCard> {
  bool _testing = false;

  /// 用 dart:ui 画一张 300x80 白底黑字 PNG，写到临时目录后返回路径。
  Future<String> _buildTestImage() async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    final ui.Paint background = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
    canvas.drawRect(const ui.Rect.fromLTWH(0, 0, 300, 80), background);

    final ui.ParagraphBuilder builder =
        ui.ParagraphBuilder(ui.ParagraphStyle(fontSize: 26))
          ..pushStyle(
            ui.TextStyle(color: const ui.Color(0xFF000000), fontSize: 26),
          )
          ..addText('OCR 12345');
    final ui.Paragraph paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: 300));
    canvas.drawParagraph(paragraph, const ui.Offset(10, 20));

    final ui.Picture picture = recorder.endRecording();
    final ui.Image image = await picture.toImage(300, 80);
    final ByteData? data = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final List<int> bytes = data == null
        ? <int>[]
        : data.buffer
              .asUint8List(data.offsetInBytes, data.lengthInBytes)
              .toList();
    picture.dispose();
    image.dispose();
    if (bytes.isEmpty) {
      throw StateError('无法生成测试图片 PNG');
    }

    final Directory dir = await getTemporaryDirectory();
    final File file = File(p.join(dir.path, 'ocr_engine_probe.png'));
    await file.writeAsBytes(bytes);
    return file.path;
  }

  Future<void> _testEngine() async {
    if (_testing) return;
    setState(() => _testing = true);
    final StorageService storage = context.read<StorageService>();
    final OcrService ocr = createOcrService(storage: storage);
    String message = '';
    try {
      final String imagePath = await _buildTestImage();
      await ocr.initEngine();
      final String text = (await ocr.recognizeRaw(<String>[imagePath])).trim();
      // 无论是否识别出文字，都附上完整诊断链，便于长按复制反馈。
      final String diagnosis = ocr.lastError ?? '（无诊断信息）';
      message =
          '识别返回文本：\n${text.isEmpty ? '（空）' : text}\n\n'
          '──── 完整诊断 ────\n$diagnosis';
    } catch (e) {
      message = '测试失败：$e\n\n${ocr.lastError ?? '（无诊断信息）'}';
    } finally {
      ocr.disposeEngine();
    }
    if (!mounted) return;
    setState(() => _testing = false);
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('引擎诊断结果'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(message)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 同时展示 Flutter 侧与 Python 引擎侧的文件日志，便于整体复制反馈。
  Future<void> _showLogs(BuildContext context) async {
    final String flutterLog = OcrLog.tail();
    final StorageService storage = context.read<StorageService>();
    final String exe = LocalPythonOcrService(storage: storage)
        .resolvedExecutable();
    final File pythonFile = File(OcrLog.pythonLogPath(exe));
    String pythonLog;
    try {
      pythonLog = pythonFile.existsSync()
          ? pythonFile.readAsStringSync()
          : '（未找到 Python 引擎日志，文件尚未生成）';
    } catch (e) {
      pythonLog = '读取失败：$e';
    }
    if (pythonLog.length > 24000) {
      pythonLog =
          '…（已省略前面 ${pythonLog.length - 24000} 字符）\n'
          '${pythonLog.substring(pythonLog.length - 24000)}';
    }
    final String text =
        '── Flutter 日志（${OcrLog.path}）──\n$flutterLog\n\n'
        '── Python 引擎日志（${pythonFile.path}）──\n$pythonLog';
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('OCR 运行日志（可长按复制）'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(text)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () {
              OcrLog.clear();
              Navigator.of(ctx).pop();
            },
            child: const Text('清空 Flutter 日志'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StorageService storage = context.read<StorageService>();
    final LocalPythonOcrService local = LocalPythonOcrService(storage: storage);
    final String path = local.resolvedExecutable();
    final bool exists = File(path).existsSync();
    final String engineLabel = storage.ocrEngine == 'cloud'
        ? '云端服务（当前配置）'
        : '本地引擎（当前配置）';
    final String diagnosis = local.lastError ?? '（无诊断信息）';

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '引擎诊断',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              '当前 OCR 引擎：$engineLabel',
              style: const TextStyle(fontSize: 12, color: kNeutralGrey),
            ),
            const SizedBox(height: 4),
            const Text(
              '解析到的引擎路径：',
              style: TextStyle(fontSize: 12, color: kNeutralGrey),
            ),
            const SizedBox(height: 4),
            SelectableText(path, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                Icon(
                  exists ? Icons.check_circle : Icons.error_outline,
                  size: 16,
                  color: exists ? kSuccessColor : kErrorColor,
                ),
                const SizedBox(width: 6),
                Text(
                  exists ? '文件存在' : '文件不存在，识别会失败',
                  style: TextStyle(
                    fontSize: 12,
                    color: exists ? kSuccessColor : kErrorColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            const Text(
              '当前状态诊断（可长按复制）：',
              style: TextStyle(fontSize: 12, color: kNeutralGrey),
            ),
            const SizedBox(height: 4),
            SelectableText(diagnosis, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _testing ? null : () => unawaited(_testEngine()),
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow, size: 18),
                  label: Text(_testing ? '测试中…' : '测试引擎'),
                ),
                OutlinedButton.icon(
                  onPressed: () async {
                    await storage.setOcrEngine('local');
                    if (!context.mounted) return;
                    setState(() {});
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('已切回本地引擎')));
                  },
                  icon: const Icon(Icons.settings_backup_restore, size: 18),
                  label: const Text('切回本地引擎'),
                ),
                OutlinedButton.icon(
                  onPressed: () => unawaited(_showLogs(context)),
                  icon: const Icon(Icons.article_outlined, size: 18),
                  label: const Text('查看运行日志'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              '关于',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 8),
            const Text(
              '水质检测仪助手 · 蓝白主题 · Android + Windows',
              style: TextStyle(fontSize: 12),
            ),
            const SizedBox(height: 4),
            Text(
              '工作空间按文件夹落盘，回收站保留 $kTrashRetentionDays 天；'
              '各工具执行完成后均可创建或导入到工作空间。',
              style: const TextStyle(fontSize: 12, color: kNeutralGrey),
            ),
          ],
        ),
      ),
    );
  }
}
