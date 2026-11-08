import '../models/instrument_type.dart';
import '../models/ocr_parse_result.dart';
import '../models/water_quality_row.dart';
import 'number_utils.dart';
import 'ocr_digits.dart';

/// 左侧菜单 / 页面噪声词：总磷·总铜屏左侧竖排菜单，OCR 常把它并入数据行。
/// 这些词绝不参与数值列判定（无论出现在行首还是行内）。
const Set<String> _menuNoiseWords = <String>{
  '数据查询',
  '历史曲线',
  '质控数据',
  '校准记录',
  '警告记录',
  '状态记录',
  '仪器信息',
  '返回',
  '设置',
  '校准',
  '维护',
  '查询',
  // 菜单词被裁掉首字的常见残缺形式。
  '据查询',
  '史曲线',
  '控数据',
  '准记录',
  '告记录',
  '态记录',
  '器信息',
};

/// 屏幕上的标题 / 按钮 / 状态提示词。倾斜拍屏 + 行聚类错乱时，这些词会
/// 单独成行或混在数据行尾部；它们不贡献任何数据信号，也不参与数值列。
const Set<String> _uiNoiseWords = <String>{
  'MCGS',
  '数据管理-水样',
  '数据管理',
  '导出成功',
  '上翻',
  '下翻',
  '水样记录',
  '标宽记录',
  '报警记录',
  '返回主质',
  '返回主页',
  '删除记录',
  'U益导出',
  '益导出',
};

/// MCGS 屏「单位」列恒为 MPN/L；OCR 常误识为 MPNAL / HPN/L / MPNL / APN/L。
const String _mcgsUnit = 'MPN/L';

/// OCR 文本 → 结构化行（按仪器类型）。
///
/// 说明：OCR 输出为无固定布局的文本，本解析器采用「逐行 + token 定位」启发式：
/// 定位日期/时间 token 作为锚点，再按各仪器列顺序做「列语义对齐」。
/// 总铜屏见 [_parseTotalCopper]，MCGS / E.co 见 [_parseMcgs] / [_parseEco]。
/// 表头行若混入数值（OCR 常把第一行数据与表头连成一行），数值会被补到紧随
/// 其后的第一条数据行，绝不整行静默丢弃，见 [parseOcrText]。
/// 菜单/按钮噪声行与「只有日期时间、无任何业务值」的空行一律跳过，见
/// [_looksLikeDataLine] 与 [_hasBusinessValue]。
/// 无法解析的行会被跳过，并通过 [OcrParseResult.warnings] 提示用户人工核对。
OcrParseResult parseOcrText(String text, InstrumentType type) {
  final List<String> lines = _normalizeLines(text);
  final List<WaterQualityRow> rows = <WaterQualityRow>[];
  final List<String> warnings = <String>[];

  // 表头行里剥出来的数值 token，等待补到下一行数据行末尾。
  List<String>? pendingHeaderTokens;
  int skipped = 0;
  for (final String rawLine in lines) {
    final String line = rawLine.trim();
    if (line.isEmpty) continue;

    if (_isHeaderLine(line, type)) {
      // 表头行可能混入第一行数据（如 MCGS 屏把 12169.00 / 12209.00 与表头
      // 识别在同一行）。剔除表头词、日期、时间后仍剩下的内容做二次提取，
      // 不整行丢弃；日期/时间是表头旁的标签噪声，绝不能被当成数据数值。
      final List<String> residual = _tokensOf(line)
          .where(
            (String t) =>
                !type.headers.contains(t) &&
                !_looksLikeDate(t) &&
                !_isTimeLikeToken(t),
          )
          .toList();
      if (residual.isNotEmpty) {
        pendingHeaderTokens = pendingHeaderTokens == null
            ? residual
            : <String>[...pendingHeaderTokens, ...residual];
      }
      continue;
    }

    final List<String> tokens = _tokensOf(line);
    // 菜单 / 按钮 / 标题噪声行直接跳过，且不消耗表头剥出来的数值，
    // 让它们留给紧随其后的第一条真正的数据行。
    if (!_looksLikeDataLine(tokens)) continue;

    final List<String>? pending = pendingHeaderTokens;
    WaterQualityRow? row;
    if (pending != null) {
      // 数值列从右往左锚定，把表头数值追加到行尾正好对应末尾两列
      // （MCGS 的 空白对照 / 测试对照，E.co 的 空白 / 检测）。
      row = _parseTokens(<String>[...tokens, ...pending], type, warnings);
      if (row == null) {
        // 合并后仍不成行：把表头数值作为独立残缺行保留，绝不静默丢弃。
        final WaterQualityRow? orphan = _parseTokens(pending, type, warnings);
        if (!_addRow(orphan, rows, type)) {
          _warnOnce(warnings, '表头行含未识别内容，已跳过，请人工核对');
        }
      }
      pendingHeaderTokens = null;
    }
    row ??= _parseTokens(tokens, type, warnings);
    if (!_addRow(row, rows, type)) skipped++;
  }

  // 表头行就是最后一行的极端情况：数值仍作为独立残缺行保留。
  if (pendingHeaderTokens != null) {
    final WaterQualityRow? orphan = _parseTokens(
      pendingHeaderTokens,
      type,
      warnings,
    );
    if (!_addRow(orphan, rows, type)) {
      _warnOnce(warnings, '表头行含未识别内容，已跳过，请人工核对');
    }
  }

  if (rows.isEmpty) {
    warnings.add('未能从 OCR 文本中解析出有效数据行，请检查图片是否清晰、表格是否完整');
  } else if (skipped > 0) {
    warnings.add('有 $skipped 行因格式不完整被跳过，请人工核对');
  }

  return OcrParseResult(instrument: type, rows: rows, warnings: warnings);
}

/// 只有含「至少一个业务值」的行才进入结果表，避免产生一堆全空行。
bool _addRow(
  WaterQualityRow? row,
  List<WaterQualityRow> rows,
  InstrumentType type,
) {
  if (row == null) return false;
  if (!_hasBusinessValue(row, type)) return false;
  rows.add(row);
  return true;
}

/// 有效业务值 = 数值或「未检出」文本。日期、时间、通道、单位、恒为 N 的
/// 数据标识都不算；只有日期/时间的行会被判为空数据行。
bool _hasBusinessValue(WaterQualityRow row, InstrumentType type) {
  final String? dateColumn = type.dateColumn;
  final String? channelColumn = type.channelColumn;
  final String? unitColumn = type.unitColumn;
  final String timeColumn = type.timeColumn;
  for (final String key in type.headers) {
    if (key == dateColumn ||
        key == timeColumn ||
        key == channelColumn ||
        key == unitColumn) {
      continue;
    }
    final String value = (row.cells[key] ?? '').trim();
    if (value.isEmpty) continue;
    if (value.contains('未检出')) return true;
    if (_toNumeric(value) != null) return true;
  }
  return false;
}

/// 行级准入：有日期/时间锚点即放行（后续再由 [_hasBusinessValue] 复核），
/// 没有锚点时至少要有 2 个数值或「未检出」信号才算数据行。
///
/// 这样 `MCGS`、`数据管理-水样 2026年9月24`（只剥出一个 24）、`13:32=45`、
/// `导出成功`、`上翻`、`报警记录`、`返回主质` 等菜单/按钮噪声行全部被挡住，
/// 而 `MPN/L 12783.00 12950.00 U益导出` 这种无日期但含两个数值的真实残缺行
/// 仍能成行。
bool _looksLikeDataLine(List<String> tokens) {
  if (_indexOfDate(tokens) >= 0 || _indexOfTime(tokens) >= 0) return true;
  int signals = 0;
  for (final String raw in tokens) {
    final String t = raw.trim();
    if (t.isEmpty) continue;
    if (_isUiNoiseToken(t) || _isMenuNoise(t)) continue;
    if (_looksLikeDate(t) || _isTimeLikeToken(t)) continue;
    if (_isNotDetectedText(t)) {
      signals++;
      continue;
    }
    if (_toNumeric(t) != null) signals++;
  }
  return signals >= 2;
}

/// 按 token 列表解析；[parseOcrText] 的表头二次提取与常规行共用此入口。
WaterQualityRow? _parseTokens(
  List<String> tokens,
  InstrumentType type,
  List<String> warnings,
) {
  switch (type) {
    case InstrumentType.mcgs:
      return _parseMcgs(tokens);
    case InstrumentType.eco:
      return _parseEco(tokens);
    case InstrumentType.totalCopper:
      return _parseTotalCopper(tokens, warnings);
  }
}

/// 总大肠菌群检测仪（MCGS）：采样日期、采样时间、总大肠杆菌、单位、
/// 空白对照、测试对照。
///
/// 不再按 rest 位置硬映射（旧实现会把 MPN/L 塞进测试对照），改为列语义对齐：
/// 1. 单位类 token（MPN/L 及其 OCR 变体）归一后只填「单位」；
/// 2. 「未检出」文本保留为「总大肠杆菌」；
/// 3. 数值列从右往左锚定：最后 = 测试对照、倒数第二 = 空白对照，
///    其余按序给「总大肠杆菌」；数值不足时宁可留空。
/// 时间形态 token 与多余日期一律不进入数值列，见 [_isNumericCandidate]。
WaterQualityRow? _parseMcgs(List<String> tokens) {
  final int dateIdx = _indexOfDate(tokens);
  final int timeIdx = _indexOfTime(tokens, startAfter: dateIdx);
  final int anchor = timeIdx >= 0 ? timeIdx : dateIdx;
  // 无日期时间锚点时（表头混入的残缺行）用全部 token 尽力成行。
  final List<String> rest = anchor >= 0 ? tokens.sublist(anchor + 1) : tokens;
  if (rest.isEmpty) return null;

  final Map<String, String> cells = <String, String>{};
  if (dateIdx >= 0) cells['采样日期'] = tokens[dateIdx];
  if (timeIdx >= 0) cells['采样时间'] = tokens[timeIdx];

  final Set<String> timeVariants = _timeVariantsOf(tokens);
  String? unit;
  String? notDetected;
  final List<String> numerics = <String>[];
  for (final String raw in rest) {
    final String t = raw.trim();
    if (t.isEmpty) continue;
    if (_isMenuNoise(t) || _isUiNoiseToken(t)) continue;
    final String? normalizedUnit = _normalizeUnit(t);
    if (normalizedUnit != null) {
      unit ??= normalizedUnit;
      continue;
    }
    if (_isNotDetectedText(t)) {
      notDetected ??= t;
      continue;
    }
    // 「未检出/Not de9698」被空格切开时，把英文碎片并回文本，
    // 其中的数字绝不进入数值列。
    if (notDetected != null && RegExp(r'^[A-Za-z]+\d+').hasMatch(t)) {
      notDetected = '$notDetected $t';
      continue;
    }
    if (!_isNumericCandidate(t, timeVariants)) continue;
    final String? value = _toNumeric(t);
    if (value != null) numerics.add(value);
    // 其余（中文噪声、非数值 token）一律忽略，绝不塞进数值列。
  }

  final int n = numerics.length;
  String result = notDetected ?? '';
  String blank = '';
  String detection = '';
  if (n >= 3) {
    detection = numerics[n - 1];
    blank = numerics[n - 2];
    if (result.isEmpty) result = numerics[0];
  } else if (n == 2) {
    blank = numerics[0];
    detection = numerics[1];
  } else if (n == 1) {
    // 只有一个数值时更像结果值，优先给「总大肠杆菌」。
    if (result.isEmpty) result = numerics[0];
  }

  cells['总大肠杆菌'] = result;
  cells['单位'] = unit ?? '';
  cells['空白对照'] = blank;
  cells['测试对照'] = detection;

  return WaterQualityRow.fromCells(
    instrument: InstrumentType.mcgs,
    cells: cells,
  );
}

/// 在线水质分析仪（E.co）：采样日期、采样时间、通道、分析结果、空白、检测。
///
/// 通道名与数值黏连由 [_tokensOf] 先在边界补空格拆开，这里再做列语义对齐：
/// 「未检出」文本保留为分析结果，其余数值从右往左锚定（检测 / 空白），
/// 剩余第一个数值给分析结果；不足时宁可留空也不串列。
/// 通道列是可选列：OCR 只认出单个字母或整列漏检时，通道留空并继续
/// best-effort 成行，绝不因为缺一个可选列丢掉整行数据。
WaterQualityRow? _parseEco(List<String> tokens) {
  final int dateIdx = _indexOfDate(tokens);
  final int timeIdx = _indexOfTime(tokens, startAfter: dateIdx);
  final int anchor = timeIdx >= 0 ? timeIdx : dateIdx;
  final List<String> rest = anchor >= 0 ? tokens.sublist(anchor + 1) : tokens;

  int channelIdx = -1;
  String? channel;
  for (int i = 0; i < rest.length; i++) {
    final String? matched = _matchChannel(rest[i]);
    if (matched != null) {
      channel = matched;
      channelIdx = i;
      break;
    }
  }
  // 通道列漏检时不再 return null：channel 保持 null（写表时留空），
  // 全部 rest token 都是数据候选，继续按列语义对齐成行。
  final List<String> after = channelIdx >= 0
      ? rest.sublist(channelIdx + 1)
      : rest;
  if (after.isEmpty) return null;

  final Set<String> timeVariants = _timeVariantsOf(tokens);
  String? notDetected;
  final List<String> numerics = <String>[];
  for (final String raw in after) {
    final String t = raw.trim();
    if (t.isEmpty) continue;
    // 通道名后若紧跟独立字母 A/B/C，跳过。
    if (_isChannelLetter(t) || _isMenuNoise(t) || _isUiNoiseToken(t)) continue;
    if (_isNotDetectedText(t)) {
      notDetected ??= t;
      continue;
    }
    // 「未检出/Not de9698」的英文碎片并回文本，9698 不被误当空白值。
    if (notDetected != null && RegExp(r'^[A-Za-z]+\d+').hasMatch(t)) {
      notDetected = '$notDetected $t';
      continue;
    }
    if (!_isNumericCandidate(t, timeVariants)) continue;
    final String? value = _toNumeric(t);
    if (value != null) numerics.add(value);
  }

  final int n = numerics.length;
  String result = notDetected ?? '';
  String blank = '';
  String detection = '';
  if (n >= 3) {
    detection = numerics[n - 1];
    blank = numerics[n - 2];
    if (result.isEmpty) result = numerics[0];
  } else if (n == 2) {
    blank = numerics[0];
    detection = numerics[1];
  } else if (n == 1) {
    if (result.isEmpty) {
      result = numerics[0];
    } else {
      detection = numerics[0];
    }
  }

  final Map<String, String> cells = <String, String>{};
  if (dateIdx >= 0) cells['采样日期'] = tokens[dateIdx];
  if (timeIdx >= 0) cells['采样时间'] = tokens[timeIdx];
  // 通道漏检时留空（fromCells 会把空串归一为 null），不挪别的列来补。
  cells['通道'] = channel ?? '';
  cells['分析结果'] = result;
  cells['空白'] = blank;
  cells['检测'] = detection;

  return WaterQualityRow.fromCells(
    instrument: InstrumentType.eco,
    cells: cells,
  );
}

/// 总铜 / 总磷在线分析仪（6 列：时间、数据结果、吸光度、数据标识、当前值、空白值）。
///
/// 「数据标识」恒为单字母 N，是**不参与计算的固定标志位**，但 RapidOCR 对深色
/// 条纹上的白色小号 N 检测不到是常态，ML Kit 又常把 N 与数字黏连。因此不再
/// 按 `rest[0..4]` 位置硬映射，改为列语义对齐：
/// 1. 分离出 N 与所有数值 token（中文菜单噪声、非数值 token 一律忽略）；
/// 2. 未识别到 N 就按常量补 'N' 并给出 warning；
/// 3. 数值列从右往左锚定：最后一个 = 空白值、倒数第二 = 当前值，
///    剩下的按序给 数据结果 / 吸光度；数值不足时按特征分配或留空，
///    绝不把数值塞进错误的列。
WaterQualityRow? _parseTotalCopper(List<String> tokens, List<String> warnings) {
  final int timeIdx = _indexOfTime(tokens);
  if (timeIdx < 0) return null;

  // 时间锚点之后才是数据列；先剔除左侧菜单噪声词（行首或夹杂在行内都有效）。
  final List<String> rest = tokens
      .sublist(timeIdx + 1)
      .where((String t) => !_isMenuNoise(t))
      .toList();
  if (rest.isEmpty) return null;

  final String timeToken = tokens[timeIdx];
  final Map<String, String> cells = <String, String>{};
  String? sampleDate;
  String? sampleTime;

  // 情况 A：日期与时间粘在同一个 token（如 2026-11-0318:00:00）→ 整串放入「时间」。
  final List<String>? embedded = _splitEmbeddedDateTime(timeToken);
  // 情况 B：日期与时间分成两个 token（如 2026-11-03 18:00:00）→ 拼接放入「时间」。
  final String? leadingDate = timeIdx > 0 && _looksLikeDate(tokens[timeIdx - 1])
      ? tokens[timeIdx - 1]
      : null;

  if (embedded != null) {
    cells['时间'] = timeToken;
    sampleDate = embedded[0];
    sampleTime = embedded[1];
  } else if (leadingDate != null) {
    cells['时间'] = '$leadingDate $timeToken';
    sampleDate = leadingDate;
    sampleTime = timeToken;
  } else {
    cells['时间'] = timeToken;
    sampleTime = timeToken;
  }

  // ---- 列语义对齐 ----
  final Set<String> timeVariants = _timeVariantsOf(tokens);
  bool hasFlag = false;
  final List<String> numerics = <String>[];
  for (final String raw in rest) {
    final String t = raw.trim();
    if (t.isEmpty) continue;
    if (t.toUpperCase() == 'N') {
      hasFlag = true;
      continue;
    }
    if (!_isNumericCandidate(t, timeVariants)) continue;
    final String? value = _toNumeric(t);
    if (value != null) numerics.add(value);
    // 其余（中文菜单词、单位、非数值噪声）一律忽略，绝不进入数值列。
  }

  // 数据标识恒为 N；未识别到时推断补齐并提示用户核对。
  cells['数据标识'] = 'N';
  if (!hasFlag) {
    _warnOnce(warnings, '未识别到「数据标识」列（该列恒为常量 N），已推断补齐为 N，请核对识别结果');
  }

  // 从右往左锚定：最后一个恒为空白值，倒数第二恒为当前值。
  String result = '';
  String absorbance = '';
  String current = '';
  String blank = '';
  final int n = numerics.length;
  if (n >= 4) {
    blank = numerics[n - 1];
    current = numerics[n - 2];
    result = numerics[0];
    absorbance = numerics[1];
  } else if (n == 3) {
    // 漏了一列：剩下那个数值按「吸光度(0~10 且至少 3 位小数)」/「数据结果」
    // 的特征分配，另一列留空，宁可留空也不塞错列。
    blank = numerics[2];
    current = numerics[1];
    if (_looksLikeAbsorbance(numerics[0])) {
      absorbance = numerics[0];
    } else {
      result = numerics[0];
    }
  } else if (n == 2) {
    current = numerics[0];
    blank = numerics[1];
  } else if (n == 1) {
    blank = numerics[0];
  }

  cells['数据结果'] = result;
  cells['吸光度'] = absorbance;
  cells['当前值'] = current;
  cells['空白值'] = blank;

  final WaterQualityRow row = WaterQualityRow.fromCells(
    instrument: InstrumentType.totalCopper,
    cells: cells,
  );
  // fromCells 的「时间」列会把整串写入 sampleTime，这里拆分为标准字段，
  // 保证时间列展示完整日期时间的同时，去重键也带上日期。
  if (sampleDate != null) row.sampleDate = sampleDate;
  // 三个分支均已为 sampleTime 赋值，流分析已将其提升为非空，无需判空。
  row.sampleTime = sampleTime;
  return row;
}

/// 是否为左侧菜单噪声词。
bool _isMenuNoise(String token) => _menuNoiseWords.contains(token.trim());

/// 是否为屏幕标题 / 按钮 / 状态提示词（含 OCR 截断的残缺形式）。
bool _isUiNoiseToken(String token) {
  final String t = token.trim();
  if (t.isEmpty) return false;
  for (final String word in _uiNoiseWords) {
    if (t == word || t.contains(word)) return true;
  }
  return false;
}

/// 是否为时间形态 token（含可选日期前缀），与 [_indexOfTime] 共用同一判定。
bool _isTimeLikeToken(String token) {
  return RegExp(
    r'^(\d{2,4}[-/.]\d{1,2}[-/.]\d{1,2})?[-/.]?\d{1,2}:\d{2}(:\d{2})?$',
  ).hasMatch(token.trim());
}

/// 本行所有时间 token 的「点分变体」：OCR 常把时间里的 `:` 误识为 `.`
/// （`9:11` → `9.11`）。这些变体绝不参与数值列，`1.0` / `1.5` 等真实
/// 业务数值不受影响（只精确比对变体，不做形态一刀切）。
Set<String> _timeVariantsOf(List<String> tokens) {
  final Set<String> variants = <String>{};
  for (final String raw in tokens) {
    if (_isTimeLikeToken(raw)) {
      variants.add(raw.trim().replaceAll(':', '.'));
    }
  }
  return variants;
}

/// 数值列候选过滤：时间本体、时间变体、多余日期、菜单/UI 噪声一律排除，
/// 保证「一行两个日期」时第二个日期不会堵住后面的列。
bool _isNumericCandidate(String token, Set<String> timeVariants) {
  final String t = token.trim();
  if (t.isEmpty) return false;
  if (timeVariants.contains(t)) return false;
  if (_isTimeLikeToken(t)) return false;
  if (_looksLikeDate(t)) return false;
  if (_isMenuNoise(t) || _isUiNoiseToken(t)) return false;
  return true;
}

/// 单位类 token 归一：MPN/L 的常见 OCR 变体统一返回 [_mcgsUnit]；
/// 非单位返回 null。必须含 'PN'，避免把 N / A / B / C / 数值误判为单位。
String? _normalizeUnit(String token) {
  final String t = token.trim().toUpperCase().replaceAll(' ', '');
  if (t.isEmpty) return null;
  // 覆盖 MPN/L、MPNL、MPNAL、HPN/L、APN/L、PN/L、PNL、PNAL、MPN 等。
  if (RegExp(r'^[MHA]?PN[/]?A?L?$').hasMatch(t)) return _mcgsUnit;
  return null;
}

/// 是否为「未检出」类文本（含中英文混排），这类文本保留为结果值，
/// 且其中的数字不得进入数值列。
bool _isNotDetectedText(String token) {
  final String t = token.trim();
  if (t.contains('未检出') || t.contains('未检')) return true;
  final String upper = t.toUpperCase();
  return upper.contains('NOT DE') ||
      upper.contains('NOTDE') ||
      upper.startsWith('NOT ');
}

/// 把 OCR 脏写法归一化为合法数值 token；非数值返回 null。
///
/// 兼容 `1-4867` → `1.4867`、`791:700` → `791.700`（把小数点位置上的 `-`/`:`
/// 还原成 `.`）。含 `:` 时只有「整数部分 ≥3 位」才视为被误识的小数点，
/// `9:11` / `11:10` / `18:00:00` 等时间形态一律排除（时间由 [_indexOfTime]
/// 单独处理）。含中文的菜单词、单字母 N/A/B/C 排除。
String? _toNumeric(String raw) {
  String t = raw.trim();
  if (t.isEmpty) return null;
  if (RegExp(r'[\u4e00-\u9fff]').hasMatch(t)) return null;
  if (RegExp(r'^[A-Za-z]$').hasMatch(t)) return null;
  t = t.replaceAll(' ', '');
  if (t.contains(':')) {
    if (!RegExp(r'^\d{3,}:\d+$').hasMatch(t)) return null;
    t = t.replaceAll(':', '.');
  } else if (RegExp(r'^\d+-\d+$').hasMatch(t)) {
    t = t.replaceAll('-', '.');
  }
  return RegExp(r'^-?\d+(\.\d+)?$').hasMatch(t) ? t : null;
}

/// 吸光度特征：0~10 且至少 3 位小数（如 0.9329 / 1.4835）。
/// 数据结果通常大于 10（25.2945 / 39.9668），据此在缺列时区分两者。
bool _looksLikeAbsorbance(String value) {
  final double? v = double.tryParse(value);
  if (v == null || v < 0 || v > 10) return false;
  final int dot = value.indexOf('.');
  return dot >= 0 && value.length - dot - 1 >= 3;
}

/// 同一条提示只加一次，避免 12 行都缺 N 时刷屏。
void _warnOnce(List<String> warnings, String message) {
  if (!warnings.contains(message)) warnings.add(message);
}

/// 判断 token 是否为日期（完整年月日、2 位年短日期或月/日）。
/// 2 位年三段（26/10/29、26/9/20）由 `\d{2,4}` 覆盖；含 `:` 的时间
/// 因分隔符不含 `:` 而不会被误判。
/// 月/日两段只允许 `-` / `/`：若允许 `.`，合法小数 `1.0` / `2.0` 会被
/// 误判为日期并从数值候选里剔除（与 [_indexOfDate] 的 short 规则保持一致）。
bool _looksLikeDate(String token) {
  final String t = token.trim();
  return RegExp(r'^\d{2,4}[-/.]\d{1,2}[-/.]\d{1,2}$').hasMatch(t) ||
      RegExp(r'^\d{1,2}[-/]\d{1,2}$').hasMatch(t);
}

/// 拆分「日期前缀 + 时间」粘连 token，返回 [日期, 时间]；不匹配返回 null。
/// 日期与时间之间允许一个可选分隔符（`-` / `.` / `/`）。
List<String>? _splitEmbeddedDateTime(String token) {
  final Match? m = RegExp(
    r'^(\d{2,4}[-/.]\d{1,2}[-/.]\d{1,2})[-/.]?(\d{1,2}:\d{2}(:\d{2})?)$',
  ).firstMatch(token);
  if (m == null) return null;
  return <String>[m.group(1)!, m.group(2)!];
}

String? _matchChannel(String token) {
  final String t = token.trim();
  if (t.contains('大肠埃希氏菌')) return '大肠埃希氏菌B';
  if (t.contains('总大肠菌群')) return '总大肠菌群A';
  if (t.contains('菌落总数')) return '菌落总数C';
  if (t == 'A' || t == 'A通道') return '总大肠菌群A';
  if (t == 'B' || t == 'B通道') return '大肠埃希氏菌B';
  if (t == 'C' || t == 'C通道') return '菌落总数C';
  return null;
}

bool _isChannelLetter(String token) {
  final String t = token.trim();
  return t == 'A' || t == 'B' || t == 'C';
}

bool _isHeaderLine(String line, InstrumentType type) {
  int matched = 0;
  for (final String h in type.headers) {
    if (line.contains(h)) matched++;
  }
  return matched >= 2;
}

int _indexOfDate(List<String> tokens, {int startAfter = -1}) {
  // 三段日期：年支持 2~4 位（26/10/29、26/9/20、2026-11-03）。
  final RegExp full = RegExp(r'^\d{2,4}[-/]\d{1,2}[-/]\d{1,2}$');
  final RegExp short = RegExp(r'^\d{1,2}[-/]\d{1,2}$');
  for (int i = startAfter + 1; i < tokens.length; i++) {
    if (full.hasMatch(tokens[i]) || short.hasMatch(tokens[i])) return i;
  }
  return -1;
}

int _indexOfTime(List<String> tokens, {int startAfter = -1}) {
  // 支持可选日期前缀与一个可选分隔符，覆盖：
  // 「18:00:00」「2026-11-0318:00:00」「26/10/2918:45」「2026-11-03.08:00:00」。
  for (int i = startAfter + 1; i < tokens.length; i++) {
    if (_isTimeLikeToken(tokens[i])) return i;
  }
  return -1;
}

List<String> _tokensOf(String line) {
  String s = NumberUtils.normalizeFullWidth(line);
  s = s.replaceAll('\t', ' ');
  // OCR 常把相邻单元格连成一个 token（如「2026-01-0108:00」），
  // 在「日期 + 时间」边界补一个空格，保证日期/时间锚点可被定位。
  // 日期分隔符兼容 . 与 -/；年支持 2~4 位以覆盖 26/10/2918:45。
  s = s.replaceAllMapped(
    RegExp(r'(\d{2,4}[-/.]\d{1,2}[-/.]\d{1,2})\D?(\d{1,2}:\d{2})'),
    (Match m) => '${m[1]} ${m[2]}',
  );
  // 「39. 9668」这类小数点后被空格切开 → 合并回「39.9668」。
  s = s.replaceAllMapped(
    RegExp(r'(\d\.)\s+(\d)'),
    (Match m) => '${m[1]}${m[2]}',
  );
  // 手机端 ML Kit 常把数据标识 N 与数字黏连：
  // 「0.9329N」→「0.9329 N」，「1.4367N828.100」→「1.4367 N 828.100」。
  s = s.replaceAllMapped(RegExp(r'(\d)([Nn])'), (Match m) => '${m[1]} ${m[2]}');
  s = s.replaceAllMapped(RegExp(r'([Nn])(\d)'), (Match m) => '${m[1]} ${m[2]}');
  // 通道名（中文 + 后缀字母 A/B/C）与数值或「未检出」文本黏连时补空格：
  // 「大肠埃希氏菌B2514」→「大肠埃希氏菌B 2514」、
  // 「大肠埃希氏菌B未检出」→「大肠埃希氏菌B 未检出」。
  // 只匹配「中文(+单个字母)」边界，绝不触碰纯英文片段，因此
  // 「未检出/Not de9698」里的 de9698 保持完整，9698 不会被误当空白值。
  s = s.replaceAllMapped(
    RegExp(r'([\u4e00-\u9fff][A-Za-z])(\d)'),
    (Match m) => '${m[1]} ${m[2]}',
  );
  s = s.replaceAllMapped(
    RegExp(r'([\u4e00-\u9fff][A-Za-z])(未检)'),
    (Match m) => '${m[1]} ${m[2]}',
  );
  s = s.replaceAllMapped(
    RegExp(r'([\u4e00-\u9fff])(\d)'),
    (Match m) => '${m[1]} ${m[2]}',
  );
  // 逐 token 纠正 OCR 形似数字字符（日期 / 时间 / 通道标识由 fixOcrDigits 保护）。
  return s
      .split(RegExp(r'\s+'))
      .where((String t) => t.isNotEmpty)
      .map(fixOcrDigits)
      .toList();
}

List<String> _normalizeLines(String text) {
  return text
      .split(RegExp(r'\r?\n'))
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}
