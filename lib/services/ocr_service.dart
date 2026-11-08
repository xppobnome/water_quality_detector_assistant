import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/platform.dart';
import '../models/instrument_type.dart';
import '../models/ocr_parse_result.dart';
import '../models/water_quality_row.dart';
import '../services/storage_service.dart';
import '../utils/ocr_parser.dart';
import 'mlkit_ocr_service.dart';
import 'ocr_log.dart';

/// OCR 识别抽象接口。
abstract class OcrService {
  /// 仅识别，返回拼接后的原始 OCR 文本（不解析）。
  ///
  /// 供 [TableRecognitionService] 自动判断仪器类型后再解析使用。
  /// 未配置 / 引擎不可用时返回空串，不抛异常。
  Future<String> recognizeRaw(List<String> imagePaths);

  /// 识别一组图片并按仪器类型解析为结构化行。
  Future<OcrParseResult> recognize(
    List<String> imagePaths,
    InstrumentType type,
  );

  /// 预启动 OCR 引擎（常驻进程 / 模型预热）。默认空实现。
  Future<void> initEngine() async {}

  /// 释放资源（关闭子进程等）。默认空实现。
  void disposeEngine() {}

  /// 最近一次识别失败 / 引擎不可用的原因（供上层提示与「引擎诊断」展示）。
  /// 默认返回 null；本地 Python 引擎与 ML Kit 各自覆盖。
  String? get lastError => null;
}

/// 基于可配置云端 OCR 服务的识别实现（跨平台，含 Windows 桌面端）。
///
/// 约定：向 [StorageService.ocrApiBaseUrl] 指向的地址以 `multipart/form-data`
/// 上传字段名为 `image` 的图片文件，返回纯文本（text/plain）或 JSON
/// `{"text": "..."}` / `{"result": "..."}`。可附加 `Authorization: Bearer <key>`。
///
/// 未配置服务地址时 [recognize] 返回空结果并附带提示，由上层提示用户去设置。
class CloudOcrService implements OcrService {
  CloudOcrService({required this.storage});

  final StorageService storage;

  @override
  Future<void> initEngine() async {}

  @override
  void disposeEngine() {}

  /// 云端服务无「引擎不可用」概念，沿用接口默认语义返回 null。
  /// [CloudOcrService] 使用 implements，需显式实现带默认值的 getter。
  @override
  String? get lastError => null;

  @override
  Future<String> recognizeRaw(List<String> imagePaths) async {
    final String? baseUrl = storage.ocrApiBaseUrl;
    if (baseUrl == null || baseUrl.isEmpty) return '';
    final StringBuffer buffer = StringBuffer();
    for (final String path in imagePaths) {
      try {
        final String text = await _recognizeOne(baseUrl, path);
        if (text.trim().isNotEmpty) {
          if (buffer.isNotEmpty) buffer.writeln();
          buffer.writeln(text.trim());
        }
      } catch (_) {
        // 单张失败不阻断其他图片。
      }
    }
    return buffer.toString();
  }

  @override
  Future<OcrParseResult> recognize(
    List<String> imagePaths,
    InstrumentType type,
  ) async {
    final String? baseUrl = storage.ocrApiBaseUrl;
    if (baseUrl == null || baseUrl.isEmpty) {
      return OcrParseResult(
        instrument: type,
        rows: const <WaterQualityRow>[],
        warnings: <String>[
          isDesktop
              ? '未配置桌面端 OCR 服务地址，请在「设置」中填写（POST 图片，返回纯文本）。'
              : '未配置 OCR 服务地址，请在「设置」中填写。',
        ],
      );
    }

    final StringBuffer buffer = StringBuffer();
    final List<String> warnings = <String>[];
    for (final String path in imagePaths) {
      try {
        final String text = await _recognizeOne(baseUrl, path);
        if (text.trim().isNotEmpty) {
          if (buffer.isNotEmpty) buffer.writeln();
          buffer.writeln(text.trim());
        }
      } catch (e) {
        warnings.add('图片识别失败：$e');
      }
    }

    if (buffer.isEmpty) {
      return OcrParseResult(
        instrument: type,
        rows: const <WaterQualityRow>[],
        warnings: <String>[
          if (warnings.isNotEmpty) ...warnings,
          '未识别到任何文字，请检查 OCR 服务是否可用或图片是否清晰',
        ],
      );
    }

    final OcrParseResult parsed = parseOcrText(buffer.toString(), type);
    if (warnings.isNotEmpty) {
      return OcrParseResult(
        instrument: parsed.instrument,
        rows: parsed.rows,
        warnings: <String>[...parsed.warnings, ...warnings],
      );
    }
    return parsed;
  }

  Future<String> _recognizeOne(String baseUrl, String imagePath) async {
    final http.MultipartRequest request = http.MultipartRequest(
      'POST',
      Uri.parse(baseUrl),
    );
    final String? key = storage.ocrApiKey;
    if (key != null && key.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $key';
    }
    request.files.add(await http.MultipartFile.fromPath('image', imagePath));

    final http.StreamedResponse response = await request.send();
    final String body = await response.stream.bytesToString();
    if (response.statusCode != 200) return '';

    final String? contentType = response.headers['content-type'];
    if (contentType != null && contentType.contains('json')) {
      try {
        final dynamic decoded = jsonDecode(body);
        if (decoded is Map<String, dynamic>) {
          return decoded['text']?.toString() ??
              decoded['result']?.toString() ??
              '';
        }
      } catch (_) {
        // 非预期 JSON，回退为原始文本。
      }
    }
    return body;
  }
}

/// 基于本地打包 Python(PaddleOCR) 可执行文件的识别实现（桌面端纯本地、离线）。
///
/// 交互协议（沿用既定设计）：
/// - Flutter 通过 [Process.start] 拉起 [executablePath] 指向的可执行文件；
/// - Python 进程启动并加载模型后，向 stdout 输出 `{"status":"ready"}`；
/// - Flutter 将图片路径写入 stdin（每行一张），Python 识别后回 `{"status":"success","text":"..."}`；
/// - 写入 `exit` 并关闭进程以释放资源。
///
/// 未找到可执行文件或引擎未能就绪时，[recognize] 返回空结果并附带提示，不抛异常。
class LocalPythonOcrService implements OcrService {
  LocalPythonOcrService({required this.storage, this.executablePath});

  final StorageService storage;

  /// 显式指定的可执行文件路径（优先于设置与默认解析）。
  final String? executablePath;

  /// 完整的多行诊断串（配置 / 路径 / 存在性 / 进程状态 / stderr / 最近错误）。
  /// 始终返回非 null，便于「引擎诊断」与 warnings 直接展示、复制。
  @override
  String? get lastError => _buildDiagnosis();

  Process? _process;
  bool _ready = false;
  bool _failed = false;
  String? _failureReason;

  /// 引擎 stderr 尾部（只保留最后 2000 字符），失败时并入诊断。
  final StringBuffer _stderrLog = StringBuffer();

  /// 最近若干条识别错误 / 空文本记录（保留最后 6 条）。
  final List<String> _recentErrors = <String>[];

  final List<Completer<Map<String, dynamic>>> _pending =
      <Completer<Map<String, dynamic>>>[];

  /// dispose 后重建，保证「失败 → 重试」时仍可投递非请求消息。
  StreamController<Map<String, dynamic>> _messageController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// 累积 stderr，只保留最后 2000 字符，避免日志无限增长。
  void _appendStderr(String chunk) {
    if (chunk.isEmpty) return;
    OcrLog.write('STDERR: ${chunk.trim()}');
    _stderrLog.write(chunk);
    final String text = _stderrLog.toString();
    if (text.length > 2000) {
      _stderrLog
        ..clear()
        ..write(text.substring(text.length - 2000));
    }
  }

  /// 记录一条识别错误（不静默跳过），供 [lastError] 展示。
  void _appendFailure(String message) {
    _recentErrors.add(message);
    if (_recentErrors.length > 6) {
      _recentErrors.removeAt(0);
    }
  }

  /// 拼装完整诊断串，便于用户长按复制反馈。
  String _buildDiagnosis() {
    final String path = resolvedExecutable();
    final bool exists = File(path).existsSync();
    final String stderr = _stderrLog.toString().trim();
    final StringBuffer sb = StringBuffer()
      ..writeln('OCR 引擎配置：${storage.ocrEngine}')
      ..writeln('解析到的引擎路径：$path')
      ..writeln('引擎文件是否存在：${exists ? '是' : '否'}')
      ..writeln('引擎进程是否存活：${_process != null ? '是' : '否'}')
      ..writeln('引擎是否就绪(ready)：${_ready ? '是' : '否'}')
      ..writeln('启动失败原因：${_failureReason ?? '无'}')
      ..writeln('最近 stderr：${stderr.isEmpty ? '（空）' : stderr}')
      ..writeln('Flutter 日志：${OcrLog.path}')
      ..writeln('Python 引擎日志：${OcrLog.pythonLogPath(path)}');
    if (_recentErrors.isNotEmpty) {
      sb.writeln('最近识别错误：');
      for (final String e in _recentErrors) {
        sb.writeln('  - $e');
      }
    }
    return sb.toString().trimRight();
  }

  @override
  Future<void> initEngine() async {
    if (_process != null) return;
    // 一次失败后不再永久不可用：先释放旧状态再重试。
    if (_failed) {
      disposeEngine();
      _stderrLog.clear();
      _recentErrors.clear();
    }
    if (_messageController.isClosed) {
      _messageController = StreamController<Map<String, dynamic>>.broadcast();
    }
    try {
      final String exe = resolvedExecutable();
      OcrLog.write('initEngine resolved=$exe exists=${File(exe).existsSync()}');
      if (!File(exe).existsSync()) {
        _failed = true;
        _failureReason =
            '未找到本地 OCR 引擎：$exe。请运行项目 python/build_engine.bat 一键打包，'
            '产物会随 Windows 应用自动分发；也可在「设置」中手动指定路径。';
        OcrLog.write('initEngine FAILED: file not found');
        return;
      }
      // 指定工作目录，保证引擎能按相对路径找到随包分发的模型。
      _process = await Process.start(
        exe,
        <String>[],
        workingDirectory: File(exe).parent.path,
      );
      OcrLog.write('Process.start OK pid=${_process!.pid}');
      _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine, onError: (_) {});
      // stderr 全量累积：这是「识别不了但看不到原因」的主因，不再静默丢弃。
      _process!.stderr
          .transform(utf8.decoder)
          .listen(_appendStderr, onError: (_) {});
      // 进程意外退出时，唤醒所有挂起请求并立即带上 stderr 失败，不空等 ready。
      _process!.exitCode.then((int code) {
        _failPending('OCR 引擎进程已退出（code=$code）');
      });
      await _waitForReady();
    } catch (e) {
      _failed = true;
      _failureReason = 'OCR 引擎启动失败：$e';
      _appendFailure('OCR 引擎启动失败：$e');
    }
  }

  /// 标记引擎不可用，并唤醒所有挂起的识别请求；带上 stderr 便于定位。
  void _failPending(String message) {
    _failed = true;
    final String stderr = _stderrLog.toString().trim();
    _failureReason ??= stderr.isNotEmpty
        ? '$message\n引擎 stderr：$stderr'
        : message;
    _ready = false;
    final List<Completer<Map<String, dynamic>>> pending =
        List<Completer<Map<String, dynamic>>>.from(_pending);
    _pending.clear();
    for (final Completer<Map<String, dynamic>> c in pending) {
      c.complete(<String, dynamic>{'status': 'error', 'message': message});
    }
  }

  void _handleLine(String line) {
    final String trimmed = line.trim();
    OcrLog.write(
      'STDOUT: ${trimmed.length > 800 ? '${trimmed.substring(0, 800)}…' : trimmed}',
    );
    if (trimmed.isEmpty) return;
    Map<String, dynamic>? msg;
    try {
      final dynamic decoded = jsonDecode(trimmed);
      if (decoded is Map<String, dynamic>) msg = decoded;
    } catch (_) {
      // 非 JSON 行（如引擎偶发日志）忽略。
      return;
    }
    if (msg == null) return;
    if (msg['status'] == 'ready') {
      _ready = true;
      return;
    }
    if (_pending.isNotEmpty) {
      _pending.removeAt(0).complete(msg);
    } else if (!_messageController.isClosed) {
      _messageController.add(msg);
    }
  }

  /// 等待 ready：45 秒上限；进程提前退出（_failed 被置位）立即返回，不空等。
  Future<void> _waitForReady() async {
    final Stopwatch sw = Stopwatch()..start();
    while (!_ready && sw.elapsed < const Duration(seconds: 45)) {
      if (_failed) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    if (!_ready && !_failed) {
      _failed = true;
      _failureReason =
          'OCR 引擎未在 45 秒内就绪（模型加载较慢或缺失，'
          '请确认已离线打包模型）。';
      _appendFailure(_failureReason!);
    }
  }

  /// 写完路径立即 flush，确保 Python 侧 stdin 马上收到，避免握手卡住。
  Future<Map<String, dynamic>> _request(String imagePath) async {
    final Completer<Map<String, dynamic>> completer =
        Completer<Map<String, dynamic>>();
    _pending.add(completer);
    try {
      _process!.stdin.writeln(imagePath);
      await _process!.stdin.flush();
    } catch (e) {
      _pending.remove(completer);
      if (!completer.isCompleted) {
        completer.complete(<String, dynamic>{
          'status': 'error',
          'message': '写入图片路径失败：$e',
        });
      }
      _appendFailure('写入图片路径失败：$e');
    }
    return completer.future;
  }

  @override
  Future<String> recognizeRaw(List<String> imagePaths) async {
    OcrLog.write(
      'recognizeRaw START count=${imagePaths.length} paths=$imagePaths',
    );
    for (final String path in imagePaths) {
      OcrLog.write('image exists=${File(path).existsSync()} path=$path');
    }

    // 注意：不能用「&& !_failed」短路，否则一次启动失败后永远不再重试。
    if (_process == null) {
      await initEngine();
    }
    if (_failed || _process == null) {
      OcrLog.write('常驻进程不可用，直接回退一次性模式');
      return _recognizeAllOnce(imagePaths);
    }

    final StringBuffer buffer = StringBuffer();
    for (final String path in imagePaths) {
      try {
        final Map<String, dynamic> msg = await _request(path);
        OcrLog.write('reply status=${msg['status']} path=$path');
        if (msg['status'] == 'success') {
          final String text = (msg['text']?.toString() ?? '').trim();
          OcrLog.write(
            'reply chars=${text.length} text=${text.substring(0, text.length > 500 ? 500 : text.length)}',
          );
          if (text.isNotEmpty) {
            if (buffer.isNotEmpty) buffer.writeln();
            buffer.writeln(text);
          } else {
            _appendFailure('引擎返回空文本：$path');
          }
        } else {
          final String reason = msg['message']?.toString() ?? '未知错误';
          _appendFailure('引擎返回错误：$reason（$path）');
        }
      } catch (e) {
        // 单张失败不阻断其他图片，但必须留下诊断，不再静默跳过。
        OcrLog.write('单张识别异常：$e path=$path');
        _appendFailure('单张识别异常：$e（$path）');
      }
    }

    // 常驻协议没产出任何文本时，自动改用一次性模式兜底。
    if (buffer.isEmpty && imagePaths.isNotEmpty) {
      OcrLog.write('常驻模式无文本，自动回退一次性模式');
      return _recognizeAllOnce(imagePaths);
    }
    OcrLog.write('recognizeRaw DONE chars=${buffer.length}');
    return buffer.toString();
  }

  /// 一次性模式兜底：逐张调用 `ocr_engine.exe --once <path>`，绕开常驻 stdin/stdout。
  Future<String> _recognizeAllOnce(List<String> imagePaths) async {
    OcrLog.write('ONCE fallback START count=${imagePaths.length}');
    final StringBuffer buffer = StringBuffer();
    for (final String path in imagePaths) {
      final String text = await _recognizeOnce(path);
      if (text.isNotEmpty) {
        if (buffer.isNotEmpty) buffer.writeln();
        buffer.writeln(text);
      }
    }
    OcrLog.write('ONCE fallback DONE chars=${buffer.length}');
    return buffer.toString();
  }

  /// 单次调用打包引擎，解析 stdout 里的 success JSON。
  Future<String> _recognizeOnce(String imagePath) async {
    final String exe = resolvedExecutable();
    OcrLog.write(
      'ONCE start exe=$exe exists=${File(exe).existsSync()} '
      'image=$imagePath imageExists=${File(imagePath).existsSync()}',
    );
    if (!File(exe).existsSync()) {
      _appendFailure('一次性模式：引擎文件不存在 $exe');
      return '';
    }
    try {
      final ProcessResult result = await Process.run(
        exe,
        <String>['--once', imagePath],
        workingDirectory: File(exe).parent.path,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 120));
      final String out = (result.stdout?.toString() ?? '').trim();
      final String err = (result.stderr?.toString() ?? '').trim();
      OcrLog.write(
        'ONCE exit=${result.exitCode} stdoutLen=${out.length} stderrLen=${err.length}',
      );
      OcrLog.write('ONCE stdout=$out');
      if (err.isNotEmpty) OcrLog.write('ONCE stderr=$err');
      for (final String raw in out.split(RegExp(r'\r?\n'))) {
        final String line = raw.trim();
        if (line.isEmpty) continue;
        try {
          final dynamic decoded = jsonDecode(line);
          if (decoded is Map<String, dynamic>) {
            if (decoded['status'] == 'success') {
              final String text = (decoded['text']?.toString() ?? '').trim();
              OcrLog.write('ONCE success chars=${text.length}');
              return text;
            }
            final String reason = decoded['message']?.toString() ?? '未知错误';
            OcrLog.write('ONCE engine error=$reason');
            _appendFailure('一次性模式引擎错误：$reason');
          }
        } catch (_) {
          // 非 JSON（引擎内部日志）忽略，继续找下一行。
        }
      }
      _appendFailure('一次性模式未返回有效结果（exit=${result.exitCode}）');
      return '';
    } catch (e) {
      OcrLog.write('ONCE exception=$e');
      _appendFailure('一次性模式异常：$e');
      return '';
    }
  }

  @override
  Future<OcrParseResult> recognize(
    List<String> imagePaths,
    InstrumentType type,
  ) async {
    if (_process == null && !_failed) {
      await initEngine();
    }
    if (_failed || _process == null) {
      return OcrParseResult(
        instrument: type,
        rows: const <WaterQualityRow>[],
        warnings: <String>[_failureReason ?? '本地 OCR 引擎不可用'],
      );
    }

    final StringBuffer buffer = StringBuffer();
    final List<String> warnings = <String>[];
    for (final String path in imagePaths) {
      try {
        final Map<String, dynamic> msg = await _request(path);
        if (msg['status'] == 'success') {
          final String text = (msg['text']?.toString() ?? '').trim();
          if (text.isNotEmpty) {
            if (buffer.isNotEmpty) buffer.writeln();
            buffer.writeln(text);
          }
        } else {
          warnings.add('图片识别失败：${msg['message'] ?? '未知错误'}');
        }
      } catch (e) {
        warnings.add('图片识别异常：$e');
      }
    }

    if (buffer.isEmpty) {
      return OcrParseResult(
        instrument: type,
        rows: const <WaterQualityRow>[],
        warnings: <String>[
          if (warnings.isNotEmpty) ...warnings,
          '未识别到任何文字，请检查图片清晰度或 OCR 引擎状态',
        ],
      );
    }

    final OcrParseResult parsed = parseOcrText(buffer.toString(), type);
    if (warnings.isNotEmpty) {
      return OcrParseResult(
        instrument: parsed.instrument,
        rows: parsed.rows,
        warnings: <String>[...parsed.warnings, ...warnings],
      );
    }
    return parsed;
  }

  /// 解析可执行文件路径（public，供设置页「引擎诊断」展示）。
  ///
  /// 优先级：显式参数 / 设置路径 > 应用 exe 同级的随应用分发目录 >
  /// 源码树 `windows/ocr_engine/`（`flutter run -d windows` 时 CMake
  /// install 可能尚未拷贝，需向上回溯最多 6 级目录查找）。
  ///
  /// 命中第一个存在的文件即返回；都不存在时返回首选路径，便于报错信息
  /// 指出「期望引擎放在哪里」。
  String resolvedExecutable() {
    final String? configured = executablePath ?? storage.ocrEnginePath;
    if (configured != null && configured.isNotEmpty) return configured;
    final String dir = File(Platform.resolvedExecutable).parent.path;
    final String exeName = Platform.isWindows ? 'ocr_engine.exe' : 'ocr_engine';
    final List<String> candidates = <String>[
      p.join(dir, 'ocr_engine', exeName), // 一键打包产物（推荐）
      p.join(dir, exeName), // 兼容旧的手工放置方式
      p.join(dir, 'data', 'ocr_engine', exeName),
      // 从应用 exe 目录向上回溯，找到源码树 windows/ocr_engine/。
      ..._sourceTreeCandidates(dir, exeName),
      // 进程工作目录同样回溯（debug 运行时 current 常为项目根）。
      ..._sourceTreeCandidates(Directory.current.path, exeName),
    ];
    for (final String candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return candidates.first;
  }

  /// 从 [start] 起向上最多 6 级，逐级拼 `<dir>/windows/ocr_engine/<exeName>`。
  static List<String> _sourceTreeCandidates(String start, String exeName) {
    final List<String> out = <String>[];
    Directory dir = Directory(start);
    for (int level = 0; level < 6; level++) {
      out.add(p.join(dir.path, 'windows', 'ocr_engine', exeName));
      final String parent = dir.parent.path;
      if (parent == dir.path) break;
      dir = Directory(parent);
    }
    return out;
  }

  @override
  void disposeEngine() {
    if (_process != null) {
      try {
        _process!.stdin.writeln('exit');
      } catch (_) {
        // 忽略：管道可能已断开。
      }
      _process!.kill();
      _process = null;
    }
    _ready = false;
    _failed = false;
    // 故意保留 _stderrLog / _recentErrors：dispose 后 lastError 仍能展示
    // 上一次失败的完整诊断，供用户复制反馈。
    if (!_messageController.isClosed) _messageController.close();
  }
}

/// 构造 OCR 服务实现（平台分流）。
///
/// - Windows / 桌面端：默认 [LocalPythonOcrService]，用 `Process.start` 拉起
///   随应用分发的 PaddleOCR 常驻引擎（纯本地、离线）；
/// - Android / iOS：默认 [MlKitOcrService]，Google ML Kit 中文模型端侧离线
///   推理，**零配置**（无后端、无 Python、无 API Key、无联网）；
/// - 用户在「设置」中显式选择「云端服务」时，任何平台都走 [CloudOcrService]。
OcrService createOcrService({required StorageService storage}) {
  final String engine = storage.ocrEngine;
  OcrLog.write(
    'createOcrService engine=$engine desktop=$isDesktop mobile=$isMobile',
  );
  if (engine == 'cloud') {
    return CloudOcrService(storage: storage);
  }
  if (isDesktop) {
    return LocalPythonOcrService(storage: storage);
  }
  if (isMobile) {
    return MlKitOcrService();
  }
  return CloudOcrService(storage: storage);
}
