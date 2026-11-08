import 'dart:async';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

import '../models/instrument_type.dart';
import '../models/ocr_parse_result.dart';
import '../models/water_quality_row.dart';
import '../utils/ocr_layout.dart';
import '../utils/ocr_parser.dart';
import 'ocr_service.dart';

/// Android / iOS 端「开箱即用」的离线 OCR 实现。
///
/// 同时使用两个 ML Kit v2 识别器：
/// - `_chinese`（中文脚本）：负责中文表头/标题，供 `detectInstrumentType` 判型；
/// - `_latin`（拉丁脚本）：阿拉伯数字识别显著更准，负责数据行数值。
///
/// 中文模型对数字容易把 0/1/8/9 等认错，早期「只用中文模型 + 整行重排」
/// 的做法会让「手机端识别的数字没一个准」。本实现把两次结果按「中文表头行
/// + 拉丁数字行」合并，既保留表头语义、又拿到准确数字。
///
/// 注意：ML Kit 仅有 Android / iOS 原生实现。Windows 桌面端由
/// [createOcrService] 路由到 [LocalPythonOcrService]，本类不会被实例化；
/// [_supported] 仍做平台守卫，避免误用时抛出 MissingPluginException。
class MlKitOcrService implements OcrService {
  MlKitOcrService();

  TextRecognizer? _chinese;
  TextRecognizer? _latin;
  String? _failureReason;

  @override
  String? get lastError => _failureReason;

  bool get _supported => Platform.isAndroid || Platform.isIOS;

  TextRecognizer? _chineseRecognizer() {
    if (!_supported) {
      _failureReason ??= 'ML Kit 仅支持 Android / iOS 端';
      return null;
    }
    if (_chinese != null) return _chinese;
    try {
      _chinese = TextRecognizer(script: TextRecognitionScript.chinese);
    } catch (e) {
      _failureReason = 'ML Kit 中文模型初始化失败：$e';
    }
    return _chinese;
  }

  TextRecognizer? _latinRecognizer() {
    if (!_supported) {
      _failureReason ??= 'ML Kit 仅支持 Android / iOS 端';
      return null;
    }
    if (_latin != null) return _latin;
    try {
      _latin = TextRecognizer(script: TextRecognitionScript.latin);
    } catch (e) {
      _failureReason = 'ML Kit 拉丁模型初始化失败：$e';
    }
    return _latin;
  }

  @override
  Future<void> initEngine() async {
    // ML Kit 无独立预热接口，提前创建两个识别器即可复用（避免每张图重建）。
    _chineseRecognizer();
    _latinRecognizer();
  }

  @override
  void disposeEngine() {
    final TextRecognizer? chinese = _chinese;
    final TextRecognizer? latin = _latin;
    _chinese = null;
    _latin = null;
    if (chinese != null) unawaited(chinese.close());
    if (latin != null) unawaited(latin.close());
  }

  @override
  Future<String> recognizeRaw(List<String> imagePaths) async {
    final TextRecognizer? chinese = _chineseRecognizer();
    final TextRecognizer? latin = _latinRecognizer();
    if (chinese == null || latin == null) return '';

    final StringBuffer buffer = StringBuffer();
    for (final String path in imagePaths) {
      try {
        if (!File(path).existsSync()) {
          _failureReason ??= '图片文件不存在：$path';
          continue;
        }
        // 注意：fromFilePath 是同步工厂构造函数，不是 Future。
        final InputImage image = InputImage.fromFilePath(path);
        final RecognizedText cn = await chinese.processImage(image);
        final RecognizedText en = await latin.processImage(image);
        final String text = _merge(cn, en);
        if (text.isNotEmpty) {
          if (buffer.isNotEmpty) buffer.writeln();
          buffer.writeln(text);
        }
      } catch (e) {
        // 单张失败不阻断其它图片；记录首个原因供 recognize() / lastError 提示。
        _failureReason ??= 'ML Kit 识别失败：$e';
      }
    }
    return buffer.toString();
  }

  /// 合并策略（简单可靠，不做逐 element 几何匹配）：
  /// 1. 两次结果各自按几何位置重排为「表格友好」文本；
  /// 2. 中文结果只保留含中文字符的行（表头/标题）；
  /// 3. 拉丁结果只保留含数字的行（数据行）；
  /// 4. 返回「中文表头行 + 拉丁数据行」；
  /// 5. 拉丁结果没有数字行时整体回退中文结果，绝不返回空。
  String _merge(RecognizedText cn, RecognizedText en) {
    final String cnText = layoutOcrLines(_elements(cn));
    final String enText = layoutOcrLines(_elements(en));
    final RegExp han = RegExp(r'[\u4e00-\u9fff]');
    final RegExp digit = RegExp(r'\d');

    final List<String> headers = cnText
        .split(RegExp(r'\r?\n'))
        .where((String l) => l.trim().isNotEmpty && han.hasMatch(l))
        .toList();
    final List<String> dataLines = enText
        .split(RegExp(r'\r?\n'))
        .where((String l) => l.trim().isNotEmpty && digit.hasMatch(l))
        .toList();

    if (dataLines.isEmpty) return cnText.trim();
    return <String>[...headers, ...dataLines].join('\n');
  }

  /// 遍历 blocks → lines → elements，用 element.boundingBox 生成 [OcrLine]。
  /// 无 element 时退回 line；完全没有结构信息时退回原始文本逐行。
  List<OcrLine> _elements(RecognizedText recognized) {
    final List<OcrLine> out = <OcrLine>[];
    for (final TextBlock block in recognized.blocks) {
      for (final TextLine line in block.lines) {
        if (line.elements.isEmpty) {
          _addLine(out, line.text, line.boundingBox);
        } else {
          for (final TextElement element in line.elements) {
            _addLine(out, element.text, element.boundingBox);
          }
        }
      }
    }
    if (out.isEmpty && recognized.text.trim().isNotEmpty) {
      int row = 0;
      for (final String raw in recognized.text.split(RegExp(r'\r?\n'))) {
        final String text = raw.trim();
        if (text.isEmpty) continue;
        out.add(OcrLine(left: 0, top: row * 24, height: 20, text: text));
        row++;
      }
    }
    return out;
  }

  /// 由几何框生成一行 OCR 文本并加入列表；空文本直接忽略。
  void _addLine(List<OcrLine> out, String raw, Rect box) {
    final String text = raw.trim();
    if (text.isEmpty) return;
    out.add(
      OcrLine(left: box.left, top: box.top, height: box.height, text: text),
    );
  }

  @override
  Future<OcrParseResult> recognize(
    List<String> imagePaths,
    InstrumentType type,
  ) async {
    if (_chineseRecognizer() == null || _latinRecognizer() == null) {
      return OcrParseResult(
        instrument: type,
        rows: const <WaterQualityRow>[],
        warnings: <String>[_failureReason ?? 'ML Kit 不可用'],
      );
    }

    final String raw = await recognizeRaw(imagePaths);
    if (raw.trim().isEmpty) {
      return OcrParseResult(
        instrument: type,
        rows: const <WaterQualityRow>[],
        warnings: <String>[_failureReason ?? '未识别到任何文字，请检查图片是否清晰、四角裁剪是否框住完整表格'],
      );
    }
    return parseOcrText(raw, type);
  }
}
