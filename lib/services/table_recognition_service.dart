import '../models/instrument_type.dart';
import '../models/ocr_parse_result.dart';
import '../models/water_quality_row.dart';
import '../utils/ocr_parser.dart';
import '../utils/table_structure_detector.dart';
import 'ocr_log.dart';
import 'ocr_service.dart';

/// 三类仪器表头列特征词的并集，仅用于「把合并 OCR 文本切成每张图一段」。
///
/// 仪器判型仍完全由 [detectInstrumentType] 负责，这里的词表不参与判型，
/// 因此不会改变任何单图的判型结果。
const List<String> _kHeaderColumnWords = <String>[
  // 总大肠菌群检测仪（MCGS）
  '采样日期', '采样时间', '总大肠杆菌', '单位', '空白对照', '测试对照',
  // 在线水质分析仪（E.co）
  '通道', '分析结果', '空白', '检测',
  // 总铜 / 总磷在线分析仪
  '时间', '数据结果', '吸光度', '数据标识', '当前值', '空白值',
];

/// 数据行特征：含「时:分」时间或年月日 / 短日期 token。
/// 表头行不含这些 token；用它把数据行排除在表头判定之外。
final RegExp _kDataRowToken = RegExp(
  r'\d{1,2}:\d{2}|\d{2,4}[-/.]\d{1,2}[-/.]\d{1,2}',
);

/// 一行是否像「表头行」：不含数据行 token，且命中至少 2 个不同列特征词。
///
/// 取 2 是为避免把只含一个词的数据行 / 页脚（如「单位：MPN/L」、
/// 「水样记录」）误判为新表头；真实表头至少含 5~6 个列词。
bool _isHeaderLineForSegment(String line) {
  if (_kDataRowToken.hasMatch(line)) return false;
  int hits = 0;
  for (final String word in _kHeaderColumnWords) {
    if (line.contains(word)) {
      hits++;
      if (hits >= 2) return true;
    }
  }
  return false;
}

/// 把 `OcrService.recognizeRaw` 拼接的多图 OCR 文本切成「每张图一段」。
///
/// `recognizeRaw` 在相邻两张图之间写了一个空行，故优先按空行切块；若某块
/// 内部又出现「新表头行」（两张图被拼在同一块、没有空行分隔），则在该表头
/// 行前二次切分。无表头的纯数据块保持为 1 段，绝不丢行；空文本返回空列表。
///
/// 纯函数：只依赖 String / List / RegExp，便于用独立 dart 脚本实跑验证。
/// 返回各段首尾去空白后的文本，行内容仅做 trim，行序不变。
List<String> splitOcrSegments(String raw) {
  if (raw.trim().isEmpty) return <String>[];
  final List<String> lines = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');

  // 1) 按空行切块；连续多个空行视为一个分隔。
  final List<List<String>> blocks = <List<String>>[];
  List<String> block = <String>[];
  for (final String sourceLine in lines) {
    final String line = sourceLine.trim();
    if (line.isEmpty) {
      if (block.isNotEmpty) {
        blocks.add(block);
        block = <String>[];
      }
    } else {
      block.add(line);
    }
  }
  if (block.isNotEmpty) blocks.add(block);

  // 2) 块内若出现第二张图的表头，再按表头二次切分。
  final List<String> segments = <String>[];
  for (final List<String> linesInBlock in blocks) {
    segments.addAll(_splitBlockByHeader(linesInBlock));
  }
  return segments;
}

/// 块内二次切分：第一张表的表头之前的行（如仪器标题、菜单噪声）归第一段；
/// 之后每遇到「且前面已有数据行」的新表头，就开一个新段。
List<String> _splitBlockByHeader(List<String> lines) {
  final List<List<String>> groups = <List<String>>[];
  List<String> current = <String>[];
  bool seenHeader = false;
  int nonHeaderSinceHeader = 0;
  for (final String line in lines) {
    final bool isHeader = _isHeaderLineForSegment(line);
    if (isHeader && seenHeader && nonHeaderSinceHeader > 0) {
      groups.add(current);
      current = <String>[];
      seenHeader = false;
      nonHeaderSinceHeader = 0;
    }
    current.add(line);
    if (isHeader) {
      seenHeader = true;
      nonHeaderSinceHeader = 0;
    } else {
      nonHeaderSinceHeader++;
    }
  }
  if (current.isNotEmpty) groups.add(current);
  return groups
      .map((List<String> group) => group.join('\n').trim())
      .where((String segment) => segment.isNotEmpty)
      .toList();
}

/// 单段解析结果：该段独立判型、实际使用的类型、解析输出。
class _SegmentParse {
  const _SegmentParse({
    required this.detected,
    required this.type,
    required this.result,
  });

  /// 该段独立判型结果；null 表示未能自动判断（走了降级）。
  final InstrumentType? detected;

  /// 实际用于 [parseOcrText] 的类型（未判出时为降级类型）。
  final InstrumentType type;

  final OcrParseResult result;
}

/// 表格结构自动识别：原始 OCR 文本 → 仪器类型判定 → 结构化行。
///
/// 去掉「手动选择仪器类型」后，由 [detectInstrumentType] 依据表头自动判定；
/// 判定失败降级为 [InstrumentType.mcgs] 并附 warning 提示人工确认。
///
/// 多图场景：`recognizeRaw` 把每张图的文本用空行拼成一个 raw。若只判一次型
/// 再解析全部行，第二张图（不同类型）的行会被按第一张的列结构解析而静默丢失。
/// 因此这里先 [splitOcrSegments] 分段，每段独立判型 + 解析，再合并全部行。
class TableRecognitionService {
  TableRecognitionService({required OcrService ocr}) : _ocr = ocr;

  final OcrService _ocr;

  /// 识别一组（已裁剪的）图片，返回结构化结果。
  Future<OcrParseResult> recognizeTable(List<String> imagePaths) async {
    OcrLog.write('recognizeTable START count=${imagePaths.length}');
    final String raw = await _ocr.recognizeRaw(imagePaths);
    OcrLog.write(
      'recognizeTable raw chars=${raw.length} preview=${raw.substring(0, raw.length > 400 ? 400 : raw.length)}',
    );
    if (raw.trim().isEmpty) {
      // 先给出可核对的上下文，再附引擎完整诊断，保证用户能看到具体失败环节。
      final List<String> warnings = <String>[
        'OCR 引擎类型：${_ocr.runtimeType}；图片张数：${imagePaths.length}；'
            '原始文本长度：${raw.length}',
      ];
      final String? lastError = _ocr.lastError;
      if (lastError != null && lastError.trim().isNotEmpty) {
        // 引擎失败原因（含路径 / 进程状态 / stderr）放在通用提示之前。
        warnings.add(lastError);
      }
      warnings.add('未识别到任何文字，请检查图片是否清晰或裁剪区域是否包含表格');
      return OcrParseResult(
        instrument: InstrumentType.mcgs,
        rows: const [],
        warnings: warnings,
        rawText: raw,
      );
    }

    // 单图绝对零回归：即便 OCR 文本内部恰好含空行，也不进入分段逻辑。
    if (imagePaths.length <= 1) {
      OcrLog.write('recognizeTable segments=1 (single image)');
      return _recognizeSingle(raw);
    }

    final List<String> segments = splitOcrSegments(raw);
    OcrLog.write('recognizeTable segments=${segments.length}');

    // 单段（多图但文本只切出一段 / 无表头）→ 与改造前完全一致的路径：
    // 整段判一次型、整段解析一次，零回归。
    if (segments.length <= 1) {
      return _recognizeSingle(raw);
    }

    // 多段：每段独立判型 + 独立解析，绝不按类型过滤行。
    final List<InstrumentType?> detectedPerSegment = <InstrumentType?>[
      for (final String segment in segments) detectInstrumentType(segment),
    ];
    // 某段表头被 OCR 漏识时，沿用其它段判出的类型，而不是一律降级为 mcgs：
    // 否则该段（可能是总铜/E.co）的数据行会被按 MCGS 解析而静默丢弃。
    // 全部段都判不出时才沿用原有的 mcgs 降级语义。
    InstrumentType fallbackType = InstrumentType.mcgs;
    for (final InstrumentType? detected in detectedPerSegment) {
      if (detected != null) {
        fallbackType = detected;
        break;
      }
    }

    final List<_SegmentParse> parts = <_SegmentParse>[];
    for (int i = 0; i < segments.length; i++) {
      final InstrumentType? detected = detectedPerSegment[i];
      final InstrumentType type = detected ?? fallbackType;
      parts.add(
        _SegmentParse(
          detected: detected,
          type: type,
          result: parseOcrText(segments[i], type),
        ),
      );
    }
    OcrLog.write(
      'recognizeTable segments=${segments.length} '
      'types=[${parts.map((_SegmentParse p) => p.type.shortLabel).join(', ')}] '
      'rows=[${parts.map((_SegmentParse p) => p.result.rows.length).join(', ')}]',
    );

    // UI 只有一套列头：统一取第一段的类型。所有段的行按原顺序原样保留，
    // 各自的 cells 键名不动（非本类型的列可能显示为空，由 warning 说明）。
    final List<WaterQualityRow> rows = <WaterQualityRow>[
      for (final _SegmentParse part in parts) ...part.result.rows,
    ];
    final InstrumentType instrument = parts.first.type;
    final Set<InstrumentType> distinctTypes = parts
        .map((_SegmentParse p) => p.type)
        .toSet();
    final bool mixed = distinctTypes.length > 1;
    final int undetected = parts
        .where((_SegmentParse p) => p.detected == null)
        .length;

    final List<String> warnings = <String>[];
    if (mixed) {
      final String labels = distinctTypes
          .map((InstrumentType t) => t.label)
          .join(' / ');
      final StringBuffer detail = StringBuffer();
      for (int i = 0; i < parts.length; i++) {
        if (i > 0) detail.write('；');
        detail.write(
          '第 ${i + 1} 段「${parts[i].type.label}」${parts[i].result.rows.length} 行',
        );
      }
      warnings.add(
        '检测到多种仪表类型（$labels），已分别解析并合并；'
        '不同类型列结构不同，建议分批识别以便分别核对与导出。',
      );
      warnings.add(
        '各段明细：$detail。表格列头按第 1 段「${instrument.label}」显示，'
        '其它类型的独有列可能显示为空（原始列值已保留），导出前请人工核对。',
      );
      if (undetected > 0) {
        warnings.add(
          '其中 $undetected 段未能自动判断仪器类型，已按「${fallbackType.label}」解析，'
          '请在表格中人工核对表头',
        );
      }
    } else if (undetected == parts.length) {
      // 全部段都判不出类型：保留改造前的降级提示语义。
      warnings.add('未能自动判断仪器类型，已按「${instrument.label}」解析，请在表格中人工核对表头');
    } else {
      // 各段判型一致：与单图一致，只出一条类型提示。
      warnings.add('已自动识别表格类型：${instrument.label}');
      if (undetected > 0) {
        warnings.add(
          '其中 $undetected 段未能自动判断仪器类型，已按「${fallbackType.label}」解析，'
          '请在表格中人工核对表头',
        );
      }
    }

    // 汇总各段解析 warning，按首次出现顺序去重，避免 8 段重复刷屏。
    final Set<String> seen = <String>{};
    for (final _SegmentParse part in parts) {
      for (final String warning in part.result.warnings) {
        if (warning.trim().isNotEmpty && seen.add(warning)) {
          warnings.add(warning);
        }
      }
    }

    return OcrParseResult(
      instrument: instrument,
      rows: rows,
      warnings: warnings,
      rawText: raw,
    );
  }

  /// 单段路径：整段判一次型、整段解析一次，逻辑与改造前逐行等价。
  OcrParseResult _recognizeSingle(String raw) {
    final InstrumentType? detected = detectInstrumentType(raw);
    final InstrumentType type = detected ?? InstrumentType.mcgs;
    final OcrParseResult parsed = parseOcrText(raw, type);
    final List<String> warnings = <String>[...parsed.warnings];
    if (detected == null) {
      warnings.insert(0, '未能自动判断仪器类型，已按「${type.label}」解析，请在表格中人工核对表头');
    } else {
      warnings.insert(0, '已自动识别表格类型：${type.label}');
    }
    return OcrParseResult(
      instrument: type,
      rows: parsed.rows,
      warnings: warnings,
      rawText: raw,
    );
  }
}
