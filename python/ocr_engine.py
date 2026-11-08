# -*- coding: utf-8 -*-
"""
Windows 桌面端本地 OCR 引擎（离线、免安装 Python）。

与 Flutter `LocalPythonOcrService` 的通信有两种模式：

【常驻模式】默认，stdin/stdout 每行一个 JSON
  1. Flutter 用 Process.start 拉起 ocr_engine.exe；
  2. 引擎加载模型后输出 {"status":"ready"}；
  3. Flutter 向 stdin 写入一行「图片绝对路径」，引擎回
     {"status":"success","text":"..."} 或 {"status":"error","message":"..."}；
  4. 写入 "exit" 或管道断开时安全退出。

【一次性模式】`ocr_engine.exe --once <图片绝对路径>`
  加载模型 → 识别 → 输出一行 JSON → 退出。用于常驻进程握手失败时兜底，
  也便于在命令行手工验证。

【日志】两侧都写文件日志，绝不写 stdout（会污染 JSON 协议）：
  - Python: 环境变量 OCR_ENGINE_LOG 指定，否则 exe 同目录 ocr_engine.log，
    再回退系统临时目录 wqa_ocr_engine.log；
  - Flutter: 系统临时目录 wqa_ocr_flutter.log（见 lib/services/ocr_log.dart）。

后端（OCR_ENGINE_BACKEND 可强制 rapid / paddle）：
  - rapid（默认）：RapidOCR = PaddleOCR 官方 PP-OCR 模型 + ONNX Runtime，模型随包内置；
  - paddle（可选）：原生 PaddleOCR，见 build_engine_paddle.bat。
"""

import datetime
import json
import os
import re
import sys
import tempfile
import time
import traceback

_LOG_PATH = None

# ---------------------------------------------------------------------------
# 列感知布局常量（按「屏类型」分族，每族 6 列）
# ---------------------------------------------------------------------------

# 表头族标识：不同仪器的 6 列表头完全不同，必须先用表头词判定属于哪一族，
# 再用该族的列中心建网格；否则 MCGS / E.co 的表头词几乎命中不了总铜族，
# _header_anchors 返回 None 会退回旧的按 y/x 拼行，导致行黏连、列错位。
_FAMILY_COPPER = "copper"   # 总铜 / 总磷在线分析仪《数据查询》
_FAMILY_MCGS = "mcgs"       # 总大肠菌群检测仪（MCGS 触摸屏）
_FAMILY_ECO = "eco"         # 在线水质分析仪（E.co）

# 总铜族：6 列固定顺序，与 Dart 端 InstrumentType.totalCopper.headers 完全一致。
_TABLE_HEADERS = ("时间", "数据结果", "吸光度", "数据标识", "当前值", "空白值")
_FLAG_COL = 3  # 「数据标识」列下标，恒为常量标志 N（仅总铜族有效）

# 表头关键词（含 OCR 常见残缺前缀），用于从框中定位 6 个列中心 cx。
# 只按「一个框命中唯一一列」计锚点，避免整行表头被合并识别时污染列中心。
_HEADER_ALIASES = (
    ("时间",),
    ("数据结果", "数据结"),
    ("吸光度", "吸光"),
    ("数据标识", "数据标"),
    ("当前值", "当前"),
    ("空白值", "空白"),
)

# MCGS 族：采样日期 / 采样时间 / 总大肠杆菌 / 单位 / 空白对照 / 测试对照。
# 别名一律用完整词：避免「空白对照」误命中总铜族 / E.co 族的「空白」、
# 「测试对照」误命中「空白对照」、「采样时间」误命中总铜族的「时间」。
_MCGS_HEADERS = (
    "采样日期", "采样时间", "总大肠杆菌", "单位", "空白对照", "测试对照",
)
_MCGS_ALIASES = (
    ("采样日期",),
    ("采样时间",),
    ("总大肠杆菌", "总大肠"),
    ("单位",),
    ("空白对照",),
    ("测试对照",),
)

# E.co 族：采样日期 / 采样时间 / 通道 / 分析结果 / 空白 / 检测。
_ECO_HEADERS = ("采样日期", "采样时间", "通道", "分析结果", "空白", "检测")
_ECO_ALIASES = (
    ("采样日期",),
    ("采样时间",),
    ("通道",),
    ("分析结果", "分析结"),
    ("空白",),
    ("检测",),
)


class _TableFamily:
    """一族 6 列表格的表头定义。

    [flag_col] 为需要补常量 'N' 的列下标：仅总铜族的「数据标识」列是 3；
    MCGS / E.co 族为 None —— 它们的第 3 列分别是「单位」「分析结果」，
    绝不能补 N。
    """

    __slots__ = ("name", "headers", "aliases", "flag_col")

    def __init__(self, name, headers, aliases, flag_col):
        self.name = name
        self.headers = headers
        self.aliases = aliases
        self.flag_col = flag_col


# 顺序即平局时的优先级：总铜族优先，保证既有总铜 / 总磷图片零回归。
_HEADER_FAMILIES = (
    _TableFamily(_FAMILY_COPPER, _TABLE_HEADERS, _HEADER_ALIASES, _FLAG_COL),
    _TableFamily(_FAMILY_MCGS, _MCGS_HEADERS, _MCGS_ALIASES, None),
    _TableFamily(_FAMILY_ECO, _ECO_HEADERS, _ECO_ALIASES, None),
)
_MIN_HEADER_ANCHORS = 4  # 少于该数量的列锚点即退回原始 _layout 行为

# 左侧竖排菜单 / 底部按钮噪声词（含被裁掉首字的残缺形式）。
# 手机拍屏时右侧按钮栏、底部翻页栏、左侧菜单会一起被 OCR 读入，需扩充。
_MENU_NOISE = frozenset((
    "数据查询", "历史曲线", "质控数据", "校准记录", "警告记录",
    "状态记录", "仪器信息", "返回", "设置", "校准", "维护", "查询",
    "据查询", "史曲线", "控数据", "准记录", "告记录", "态记录", "器信息",
    "U盘导出", "ST", "ET", "st", "et",
    # MCGS / E.co 拍屏新增：标题栏、左右侧按钮、底部翻页 / 记录按钮。
    "数据管理-水样", "2026年9月24", "13:32=45", "MCGS", "E.co",
    "删除记录", "册除记录", "U益导出", "导出成功", "上翻", "下翻",
    "水样记录", "标宽记录", "标定记录", "报警记录", "操作记录",
    "返回主质", "返回主页", "提示：", "已导出数日", "在线水质分析仪",
))
_TIME_TOKEN_RE = re.compile(r"\d{1,2}:\d{2}")
# 数据行「日期+时间」形态（如 2026-11-0318:00:00 / 2026-11-03 18:00:00 /
# 2026-10-30 08:00:00）。表头「时间」没被识别出来时，用它从数据行反推
# 第 0 列真实中心，避免外推值把时间列整体切掉。
_DATETIME_TOKEN_RE = re.compile(
    r"\d{4}\s*[-/]\s*\d{1,2}\s*[-/]\s*\d{1,2}\s*\d{1,2}:\d{2}(?::\d{2})?"
)
# 数据行日期 token：同时覆盖总铜族 4 位年（2026-11-03）与
# MCGS / E.co 族 2 位年短日期（26/9/20）。倾斜模型用它定位「行锚」左列。
_DATE_TOKEN_RE = re.compile(r"\d{1,4}\s*[-/.]\s*\d{1,2}\s*[-/.]\s*\d{1,2}")
# 倾斜模型右锚列（末列数值）token：整数或带小数点的数值，排除 HH:MM 时间。
_RIGHT_NUMERIC_RE = re.compile(r"^\d+(?:\.\d+)?$")
# 由左右锚列基线差推导的倾斜斜率小于该阈值时视作正对拍摄，不做校正，
# 保证总铜 / E.co 等水平表格完全沿用原聚类（零回归）。
_SKEW_MIN_SLOPE = 0.010
# 「行坐标」与最近整数行的最大允许偏差，超出的框视为行间噪声剔除。
_SKEW_ROW_TOL = 0.45
# 6 列表格中的数值列（数据行判定用；与 _DECIMAL_NUMERIC_COLS 相同）。
_GRID_NUMERIC_COLS = (1, 2, 4, 5)

# ---------------------------------------------------------------------------
# 超大裁剪图条件缩放（只调尺寸，绝不改 CLAHE / 锐化 / 直方图）
# ---------------------------------------------------------------------------
# 四角透视裁剪会把图片放大约 1.45 倍（实测原图 1920 宽 -> 裁剪图 2786 宽），
# RapidOCR 内部 limit_side_len=736 下采样后小号数字被糊没（实跑 9913/740/
# 9482/9888 全部漏检，9888 误识成 8886）。仅当宽度 > 阈值时用 INTER_AREA
# 缩到 [_LARGE_IMAGE_SCALE] 再识别，抵消过度放大；正常尺寸（1920 宽原图 /
# 总铜屏）完全不处理，保证零回归。CLAHE / 锐化会破坏表头识别，禁止使用。
_LARGE_IMAGE_MIN_WIDTH = 2000
_LARGE_IMAGE_SCALE = 0.75

# ---------------------------------------------------------------------------
# 列级小数点补正常量（保守、可审计；仅作用于数值列）
# ---------------------------------------------------------------------------

# 6 列表格里 col 0=时间、col 3=数据标识(恒为 N)，这两列绝不参与补正。
_DECIMAL_NUMERIC_COLS = (1, 2, 4, 5)
# token 允许出现的字符：数字、小数点、以及 OCR 常见误识分隔符。
# 含中文 / 字母 / 其它符号的单元格一律跳过，绝不改动。空格仍放行，是为了
# 让 '39. 9668' 这类「小数点后被切成空格」的输入能进入归一化。
_DECIMAL_TOKEN_RE = re.compile(r"^[\d\.\-:,·。 ]+$")
# 把连续的一个或多个误识分隔符折叠成单个 '.'。
# 绝不含空格：空格是「同一列落两个框 / 表头数值追加」时多值 cell 的分隔
# （如 '12169 12209'），把空格当小数点会把两个独立数值合并成一个假数值，
# 属于确定性的数据损坏 —— 宁可不修，也绝不能合并。
_DECIMAL_SEP_RE = re.compile(r"[\-:,·。.]+")
# 仅「小数点后跟空格」这一种 OCR 切分形态：'39. 9668' / '2022. 950'。
# 只删紧跟在「数字+点」之后、且后面是数字的空格，不与多值空格混淆：
# '39. 9668' 是「点+空格+数字」，'12169 12209' 是「数字+空格+数字」。
_DECIMAL_DOT_SPACE_RE = re.compile(r"(?<=\d\.)\s+(?=\d)")
# 兜底闸：cell 内存在「数字 + 空格 + 数字」= 多个独立数值，一律不改动。
_DECIMAL_MULTI_VALUE_RE = re.compile(r"\d\s+\d")
_DECIMAL_LEGAL_RE = re.compile(r"^\d+\.\d+$")
_DECIMAL_INT_RE = re.compile(r"^\d+$")
# 时间形态 HH:MM / HH:MM:SS，归一化时跳过，避免把 18:00 变成 18.00。
_DECIMAL_TIME_RE = re.compile(r"^\d{1,2}:\d{2}(:\d{2})?$")
_DECIMAL_DATE_RE = re.compile(r"^\d{4}[\-/]\d{1,2}[\-/]\d{1,2}")
_DECIMAL_SIGN_MIN_ROWS = 3       # 主签名至少要 3 行一致
_DECIMAL_SIGN_MIN_RATIO = 0.60   # 且占该列带小数点行数 >= 60%
_DECIMAL_PLAIN_INT_MAX_LEN = 4   # 短的非前导零整数视为合理整数，不插点


def _log_path():
    """挑一个可写的日志文件路径（只探测一次）。"""
    global _LOG_PATH
    if _LOG_PATH:
        return _LOG_PATH
    candidates = [
        os.environ.get("OCR_ENGINE_LOG"),
        None,
        os.path.join(tempfile.gettempdir(), "wqa_ocr_engine.log"),
    ]
    base = getattr(sys, "_MEIPASS", None) or os.path.dirname(
        os.path.abspath(sys.executable)
    )
    candidates[1] = os.path.join(base, "ocr_engine.log")
    for candidate in candidates:
        if not candidate:
            continue
        try:
            folder = os.path.dirname(os.path.abspath(candidate))
            if not os.path.isdir(folder):
                os.makedirs(folder, exist_ok=True)
            with open(candidate, "a", encoding="utf-8"):
                pass
            _LOG_PATH = candidate
            return candidate
        except Exception:  # noqa: BLE001
            continue
    return None


def log(message):
    """追加一行日志并立即落盘；任何失败都静默忽略，绝不影响识别流程。"""
    try:
        path = _log_path()
        if not path:
            return
        stamp = datetime.datetime.now().isoformat(timespec="milliseconds")
        with open(path, "a", encoding="utf-8") as handle:
            handle.write("[%s] %s\n" % (stamp, message))
            handle.flush()
    except Exception:  # noqa: BLE001
        pass


def _setup_stdio():
    """Windows 控制台默认 GBK，统一为 UTF-8，避免中文路径/文本乱码。"""
    for name in ("stdout", "stdin", "stderr"):
        stream = getattr(sys, name, None)
        if stream is None:
            log("stdio %s is None (no reconfigure)" % name)
            continue
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")
            log("stdio %s reconfigured -> utf-8" % name)
        except Exception as e:  # noqa: BLE001
            log("stdio %s reconfigure failed: %r" % (name, e))


def _emit(obj):
    line = json.dumps(obj, ensure_ascii=False)
    log("EMIT %s" % line[:1000])
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def _base_dir():
    return getattr(sys, "_MEIPASS", None) or os.path.dirname(
        os.path.abspath(sys.executable)
    )


def _layout(items):
    """[(left, top, height, cx, text), ...] -> 表格友好文本（原始行为）。

    与 Dart lib/utils/ocr_layout.dart 的 layoutOcrLines 算法保持一致。
    [items] 现为 5 元组（新增中心 x），这里只用 left/top/height/text，
    因此对 4 元组或 5 元组都兼容，保证非 6 列表格仪器的输出完全不变。
    """
    if not items:
        return ""
    ordered = sorted(items, key=lambda e: (e[1], e[0]))
    rows = []
    for entry in ordered:
        left, top, height, text = entry[0], entry[1], entry[2], entry[-1]
        center_y = top + height / 2.0
        if not rows:
            rows.append([(left, center_y, height, text)])
            continue
        current = rows[-1]
        anchor_y = sum(e[1] for e in current) / len(current)
        max_height = max([e[2] for e in current] + [height])
        tolerance = max(6.0, max_height * 0.6)
        if abs(center_y - anchor_y) <= tolerance:
            current.append((left, center_y, height, text))
        else:
            rows.append([(left, center_y, height, text)])

    lines = []
    for row in rows:
        row.sort(key=lambda e: e[0])
        line = " ".join(e[3].strip() for e in row if e[3].strip())
        if line:
            lines.append(line)
    return "\n".join(lines)


def _add_box(items, poly, text):
    """记录 (left, top, height, cx, text)。

    cx 为框中心 x = (min(xs)+max(xs))/2，是列感知布局归列的依据。
    """
    if not text:
        return
    try:
        xs = [float(p[0]) for p in poly]
        ys = [float(p[1]) for p in poly]
    except (TypeError, ValueError, IndexError):
        return
    left, top = min(xs), min(ys)
    height = max(ys) - min(ys)
    cx = (min(xs) + max(xs)) / 2.0
    items.append((left, top, height, cx, str(text)))


def _median(values):
    """数值列表中位数；空列表返回 0。"""
    ordered = sorted(values)
    n = len(ordered)
    if n == 0:
        return 0.0
    if n % 2:
        return ordered[n // 2]
    return (ordered[n // 2 - 1] + ordered[n // 2]) / 2.0


def _is_noise_text(text):
    """左侧菜单 / 底部按钮 / 仪器信息噪声词判定。"""
    t = (text or "").strip()
    if not t:
        return False
    if t in _MENU_NOISE:
        return True
    # 菜单词残缺或与相邻字符粘连时，仅当噪声词占主体才判定，避免误伤数值。
    for word in _MENU_NOISE:
        if len(word) >= 3 and word in t and len(t) <= len(word) + 3:
            return True
    # 仪器信息条码 / 307A 等长数字不在这里按文本过滤（可能误伤合法整数值），
    # 而是由 _table_grid 的「非表头行必须含时间锚点」整行剔除。
    return False


def _match_header_columns(text, aliases):
    """一个框文本命中 [aliases] 中哪些列，返回列下标集合。"""
    return {
        col
        for col, words in enumerate(aliases)
        if any(word in text for word in words)
    }


def _header_anchors(items):
    """判定 OCR 文本属于哪一族 6 列表头，并返回该族的列中心。

    依次用 [_HEADER_FAMILIES] 的别名表统计「命中唯一一列的框」覆盖了多少列，
    取覆盖列数最多的一族；平局按 [_HEADER_FAMILIES] 顺序（总铜族优先），
    保证既有总铜 / 总磷图片零回归。覆盖列少于 [_MIN_HEADER_ANCHORS] 时
    返回 None，调用方据此退回原始 [_layout] 行为。

    返回 (centers, header_cy, family)；未命中列用已命中锚点的最小二乘
    直线外推补全，header_cy 为表头框最小 cy。
    """
    best = None  # (hit_count, family, found, header_cys)
    for family in _HEADER_FAMILIES:
        found = {}  # col -> [cx, ...]
        header_cys = []
        for entry in items:
            if len(entry) < 5:
                continue
            text = entry[-1].strip()
            if not text:
                continue
            matched = _match_header_columns(text, family.aliases)
            # 一个框同时命中多列表头（整行表头被合并识别）→ 不用它定位列中心。
            if len(matched) != 1:
                continue
            found.setdefault(matched.pop(), []).append(entry[3])
            header_cys.append(entry[1] + entry[2] / 2.0)
        hit = len(found)
        if best is None or hit > best[0]:
            best = (hit, family, found, header_cys)

    if best is None or best[0] < _MIN_HEADER_ANCHORS:
        return None
    hit, family, found, header_cys = best

    known_cols = sorted(found)
    known_cx = [sorted(found[c])[len(found[c]) // 2] for c in known_cols]
    if len(known_cols) >= 2:
        n = len(known_cols)
        mean_x = sum(known_cols) / n
        mean_y = sum(known_cx) / n
        den = sum((c - mean_x) ** 2 for c in known_cols)
        slope = (sum((known_cols[i] - mean_x) * (known_cx[i] - mean_y)
                     for i in range(n)) / den) if den else 0.0
        intercept = mean_y - slope * mean_x
    else:
        slope = 0.0
        intercept = known_cx[0]

    exact = dict(zip(known_cols, known_cx))
    centers = [exact.get(col, intercept + slope * col)
               for col in range(len(family.headers))]
    header_cy = min(header_cys) if header_cys else 0.0
    log("header family=%s anchors=%d centers=%r"
        % (family.name, hit, centers))
    return centers, header_cy, family


def _cluster_rows(items):
    """按 y 中心聚类成视觉行（与 [_layout] 相同的容差公式）。"""
    ordered = sorted(items, key=lambda e: (e[1], e[3]))
    rows = []
    anchors = []
    for entry in ordered:
        center_y = entry[1] + entry[2] / 2.0
        if rows:
            anchor_y = sum(anchors[-1]) / len(anchors[-1])
            max_height = max([e[2] for e in rows[-1]] + [entry[2]])
            tolerance = max(6.0, max_height * 0.6)
            if abs(center_y - anchor_y) <= tolerance:
                rows[-1].append(entry)
                anchors[-1].append(center_y)
                continue
        rows.append([entry])
        anchors.append([center_y])
    return rows


class _SkewModel:
    """手机拍屏「倾斜 + 透视」的行坐标模型。

    同一视觉行的框，其 cy 随 cx 线性变化（倾斜），且行距也随 cx 线性变化
    （透视把右半屏拉长：MCGS 实测左列行距 ~53px、右列 ~62px）。
    因此用左右两个锚列各自的「首行基线 + 行距」做插值：

        t      = (cx - x_left) / (x_right - x_left)
        base   = base_left   + (base_right   - base_left)   * t
        pitch  = pitch_left  + (pitch_right  - pitch_left)  * t
        row    = (cy - base) / pitch

    同一视觉行的所有框会得到几乎相同的整数 row（表头为 -1），
    比「全局减去 slope*cx」更贴合透视屏，能逐行分开 5 行数据。
    """

    __slots__ = ("x_left", "base_left", "pitch_left",
                 "x_right", "base_right", "pitch_right", "n_rows")

    def __init__(self, x_left, base_left, pitch_left,
                 x_right, base_right, pitch_right, n_rows):
        self.x_left = x_left
        self.base_left = base_left
        self.pitch_left = pitch_left
        self.x_right = x_right
        self.base_right = base_right
        self.pitch_right = pitch_right
        self.n_rows = n_rows

    def row_index(self, cx, cy):
        """返回该框所属的整数行号；落在行间或表外返回 None。"""
        span = self.x_right - self.x_left
        if span <= 1.0:
            return None
        t = (cx - self.x_left) / span
        base = self.base_left + (self.base_right - self.base_left) * t
        pitch = self.pitch_left + (self.pitch_right - self.pitch_left) * t
        if pitch <= 1.0:
            return None
        coord = (cy - base) / pitch
        idx = int(round(coord))
        # 表头行（idx=-1）到末数据行（idx=n_rows-1）之外一律剔除，
        # 顺带过滤掉表格上方标题栏与下方翻页 / 按钮栏。
        if idx < -1 or idx >= self.n_rows:
            return None
        if abs(coord - idx) > _SKEW_ROW_TOL:
            return None
        return idx


def _median_pitch(cys):
    """一列锚点 cy 的行距中位数（只取正间隔，抗个别漏检）。"""
    diffs = [cys[i + 1] - cys[i] for i in range(len(cys) - 1)]
    positive = [d for d in diffs if d > 0]
    return _median(positive) if positive else 0.0


def _fit_skew_model(items, centers, header_cy, gap):
    """从左右锚列拟合 [_SkewModel]；正对拍摄 / 锚点不足返回 None。

    左锚列 = 第 0 列日期框（26/9/20、2026-11-03 ...）；
    右锚列 = 末列数值框（12209.00、3570.500 ...）。
    两列各按 cy 排序，取首个数据行 cy 为基线、相邻差中位数为行距。
    """
    left_limit = centers[0] + 0.5 * gap
    right_limit = centers[-2] + 0.3 * gap
    left = []
    right = []
    for entry in items:
        if len(entry) < 5:
            continue
        text = entry[-1].strip()
        if not text:
            continue
        cx = entry[3]
        cy = entry[1] + entry[2] / 2.0
        if cy <= header_cy:
            continue  # 表头及以上（标题栏 / 系统时间）不是数据行锚点
        if cx <= left_limit and _DATE_TOKEN_RE.search(text):
            left.append((cx, cy))
        elif cx >= right_limit and _RIGHT_NUMERIC_RE.match(text):
            right.append((cx, cy))

    left.sort(key=lambda p: p[1])
    right.sort(key=lambda p: p[1])
    if len(left) < 3 or len(right) < 3:
        return None
    if abs(len(left) - len(right)) > 1:
        return None  # 两列行数差异过大，锚点不可靠

    x_left = _median([p[0] for p in left])
    x_right = _median([p[0] for p in right])
    if x_right - x_left < gap:
        return None
    pitch_left = _median_pitch([p[1] for p in left])
    pitch_right = _median_pitch([p[1] for p in right])
    if pitch_left <= 1.0 or pitch_right <= 1.0:
        return None
    ratio = pitch_right / pitch_left
    if ratio < 0.5 or ratio > 2.0:
        return None  # 行距比失真，可能是锚点串列
    base_left = left[0][1]
    base_right = right[0][1]
    slope = (base_right - base_left) / (x_right - x_left)
    if abs(slope) < _SKEW_MIN_SLOPE:
        return None  # 正对拍摄，沿用原聚类，零回归
    n_rows = max(len(left), len(right))
    log("skew model: slope=%.4f base=(%.1f,%.1f) pitch=(%.1f,%.1f) "
        "x=(%.1f,%.1f) rows=%d"
        % (slope, base_left, base_right, pitch_left, pitch_right,
           x_left, x_right, n_rows))
    return _SkewModel(x_left, base_left, pitch_left,
                      x_right, base_right, pitch_right, n_rows)


def _cluster_rows_skewed(items, model):
    """按「行坐标」重聚类：返回 [(row_index, [entry, ...]), ...]。"""
    grouped = {}
    for entry in items:
        if len(entry) < 5:
            continue
        cy = entry[1] + entry[2] / 2.0
        idx = model.row_index(entry[3], cy)
        if idx is None:
            continue
        grouped.setdefault(idx, []).append(entry)
    return [(idx, grouped[idx]) for idx in sorted(grouped)]


def _hour_key(text):
    """取行内首个 HH:MM 作为数据行身份（用于主/补充网格对齐）。"""
    match = _TIME_TOKEN_RE.search(text or "")
    return match.group(0) if match else None


def _time_column_center(items, header_cy):
    """从表头下方的「日期+时间」框估计「时间」列真实中心 cx。

    表头「时间」没被识别出来时，[_header_anchors] 的第 0 列只是外推值，
    会明显偏右；数据行里成列的日期时间框才是可靠锚点。标题栏系统时间的
    cy 小于表头 cy，用 `cy > header_cy` 排除。返回 cx 中位数，无候选返回 None。
    """
    cxs = []
    for entry in items:
        if len(entry) < 5:
            continue
        text = entry[-1].strip()
        if not text or not _DATETIME_TOKEN_RE.search(text):
            continue
        if entry[1] + entry[2] / 2.0 <= header_cy:
            continue
        cxs.append(entry[3])
    if not cxs:
        return None
    return _median(cxs)


def _has_data_line(text):
    """文本里是否存在含时间或数字的行（纯表头行不含数字，会判为 False）。"""
    for line in (text or "").splitlines():
        stripped = line.strip()
        if stripped and (_TIME_TOKEN_RE.search(stripped)
                         or re.search(r"\d", stripped)):
            return True
    return False


def _table_grid(items):
    """把散落框整理为定长 6 列网格。

    返回 (centers, header_cy, rows, family)，rows 元素为
    {'cy', 'header', 'cells': [str x 6], 'key'}；无足够表头锚点返回 None。

    正对拍摄时沿用原 [_cluster_rows]（按 y 均值聚类）；手机拍屏的倾斜 +
    透视会让同一视觉行的 cy 随 cx 系统性下移、且右半屏行距被拉大，此时
    [_fit_skew_model] 拟合「行坐标」，用 [_cluster_rows_skewed] 逐行归位。
    """
    anchors = _header_anchors(items)
    if anchors is None:
        return None
    centers, header_cy, family = anchors
    ncol = len(family.headers)
    gaps = [centers[i + 1] - centers[i] for i in range(len(centers) - 1)]
    gap = _median([g for g in gaps if g > 0]) or 1.0

    # 表头「时间」缺失时第 0 列是外推值（CROP1 实测 857.7，真实约 651），
    # 会连 left_bound 一起偏右，把整列时间框切掉。用数据行的日期时间框
    # 反推真实中心修正它；偏差超过 0.3*gap 才动，避免干扰正常的图。
    # 仅总铜族有「日期+时间」合并框；MCGS / E.co 第 0 列是「采样日期」。
    if family.flag_col is not None:
        time_cx = _time_column_center(items, header_cy)
        if time_cx is not None and abs(time_cx - centers[0]) > 0.3 * gap:
            log("time column center corrected from=%.1f to=%.1f (gap=%.1f)"
                % (centers[0], time_cx, gap))
            centers[0] = time_cx

    # 左侧菜单 / 右侧越界框：cx 明显落在第一列左侧或末列右侧即剔除。
    # 修正后 centers[0] 即真实时间列中心，left_bound 不再基于外推值。
    left_bound = centers[0] - 0.60 * gap
    right_bound = centers[-1] + 0.80 * gap

    kept = []
    for entry in items:
        if len(entry) < 5:
            continue
        text = entry[-1].strip()
        if not text or _is_noise_text(text):
            continue
        cx = entry[3]
        if cx < left_bound or cx > right_bound:
            continue
        kept.append(entry)

    skew = _fit_skew_model(kept, centers, header_cy, gap)
    if skew is not None:
        grouped = _cluster_rows_skewed(kept, skew)
    else:
        grouped = [(None, cluster) for cluster in _cluster_rows(kept)]

    rows = []
    for row_index, cluster in grouped:
        cells = [[] for _ in range(ncol)]
        cys = []
        for entry in cluster:
            text = entry[-1].strip()
            if not text:
                continue
            col = min(range(len(centers)),
                      key=lambda i: abs(centers[i] - entry[3]))
            cells[col].append((entry[3], text))
            cys.append(entry[1] + entry[2] / 2.0)
        texts = [" ".join(t for _, t in sorted(pairs)) for pairs in cells]
        cy = sum(cys) / len(cys) if cys else 0.0
        # 表头以上的标题栏（仪器名 / 系统时间）不参与数据行。
        if cy < header_cy - 20:
            continue
        if row_index is not None:
            # 倾斜屏：行号由模型明确给出，表头即 -1。
            is_header = row_index == -1
        else:
            header_hits = sum(1 for kw in family.headers
                              if any(kw in t for t in texts))
            is_header = header_hits >= 2
        # 时间锚点优先取「时间」列，找不到再退到相邻列 / 整行拼接：
        # 表头「时间」缺失或 OCR 把日期时间挤到别的列时，整行仍有锚点。
        key = _hour_key(texts[0])
        if key is None and len(texts) > 1:
            key = _hour_key(texts[1])
        if key is None:
            key = _hour_key(" ".join(texts))
        # 至少 2 个数值列非空，避免标题栏系统时间 / 底部按钮被当成数据行。
        numeric_filled = sum(
            1 for col in _GRID_NUMERIC_COLS
            if col < len(texts) and texts[col].strip()
        )
        # 非表头行必须含时间锚点且有数值：借此过滤底部按钮 / 仪器信息 /
        # 条码数字，也保证混进来的菜单残词不会单独成行。
        if not is_header and (key is None or numeric_filled < 2):
            continue
        rows.append({"cy": cy, "header": is_header,
                     "cells": texts, "key": key})
    return centers, header_cy, rows, family


def _is_decimal_time_like(text):
    """时间 / 日期形态 token 判定；这类 token 一律跳过归一化。"""
    t = (text or "").strip()
    if not t:
        return False
    if _DECIMAL_TIME_RE.match(t):
        return True
    if t.count(":") >= 2:
        return True
    if _DECIMAL_DATE_RE.match(t):
        return True
    return False


def _normalize_decimal_token(text):
    """token 级温和归一化：把误识分隔符折叠成 '.'。

    仅当 cell 由「数字 + 分隔字符 + 数字」构成、且归一后形如 ^\\d+\\.\\d+$
    时才改；含中文/字母、时间形态、多个独立数值混合的 token 一律跳过。
    返回 (归一化后的文本, 是否发生变化)；未变化时返回原始文本。

    空格处理（避免把两个数值合并成一个假小数）：
      - 空格只用于修「小数点被 OCR 切成空格」的形态（'39. 9668'），
        在折叠分隔符之前单独删掉「数字+点」之后紧跟数字的那个空格；
      - 折叠分隔符的集合 [_DECIMAL_SEP_RE] 绝不含空格；
      - 兜底闸：删完点后空格仍含「数字+空格+数字」的多值 cell
        （'12169 12209' / '12076 2501.500'）直接放弃，绝不合成单值。
    """
    original = text if text is not None else ""
    t = original.strip()
    if not t or not _DECIMAL_TOKEN_RE.match(t):
        return original, False
    if _is_decimal_time_like(t):
        return original, False
    if _DECIMAL_LEGAL_RE.match(t):
        return original, False
    # 先单独删「点 + 空格 + 数字」里的空格：'39. 9668' -> '39.9668'。
    # 「数字 + 空格 + 数字」不受影响，交由下面的兜底闸拦截。
    de_spaced = _DECIMAL_DOT_SPACE_RE.sub("", t)
    # 兜底闸：仍是「数字+空格+数字」= 多值 cell，一律不改动。宁可不修，
    # 也绝不把 '12169 12209' 变成 '12169.12209' 这种确定性数据损坏。
    if _DECIMAL_MULTI_VALUE_RE.search(de_spaced):
        return original, False
    collapsed = _DECIMAL_SEP_RE.sub(".", de_spaced).strip(".")
    if collapsed != t and _DECIMAL_LEGAL_RE.match(collapsed):
        return collapsed, True
    return original, False


def _decimal_signature(value):
    """合法小数 -> (整数位数, 小数位数)；否则返回 None。"""
    if not _DECIMAL_LEGAL_RE.match(value or ""):
        return None
    head, _, tail = (value or "").partition(".")
    return len(head), len(tail)


def _dominant_decimal_signature(values):
    """统计某列的主签名；无明确主签名返回 None。

    条件：出现次数 >= [_DECIMAL_SIGN_MIN_ROWS] 且占该列带小数点行数
    >= [_DECIMAL_SIGN_MIN_RATIO]。签名分散或样本太少都不启用补正。
    """
    counts = {}
    total = 0
    for value in values:
        signature = _decimal_signature((value or "").strip())
        if signature is None:
            continue
        total += 1
        counts[signature] = counts.get(signature, 0) + 1
    if not counts or total == 0:
        return None
    best = max(counts, key=lambda sig: (counts[sig], -sig[0], -sig[1]))
    if counts[best] < _DECIMAL_SIGN_MIN_ROWS:
        return None
    if counts[best] / float(total) < _DECIMAL_SIGN_MIN_RATIO:
        return None
    return best


def _looks_like_plain_integer(value):
    """短的非前导零纯整数视为「本来就在合理纯整数范围内」，不插点。"""
    return not value.startswith("0") and len(value) <= _DECIMAL_PLAIN_INT_MAX_LEN


def _fix_decimal_points(rows):
    """列级小数点补正（保守、可审计），就地修改 rows 并返回 rows。

    只处理数值列 [_DECIMAL_NUMERIC_COLS]；时间列(0)与数据标识列(3)绝不
    处理，表头行整体跳过。分两个阶段：

      A) token 级温和归一化：把误识分隔符 `- : , · 。 空格` 折叠成 '.'，
         仅当结果形如 ^\\d+\\.\\d+$ 才改（如 `39. 9668` -> `39.9668`、
         `791:700` -> `791.700`、`1-4867` -> `1.4867`）。
      B) 列级插点：从已带合法小数点的行统计 (整数位数, 小数位数) 主签名
         （至少 3 行一致且占带小数点行数 >=60% 才启用），对总位数恰好
         等于主签名位数、且不像合理纯整数的 ^\\d+$ 串按签名插入小数点
         （如 `04669` -> `0.4669`、`252945` -> `25.2945`）。

    每次改动写一条文件日志 `decimal fixed col=%d row=%s from=%r to=%r`，
    无改动不写日志。宁可不补，也不造出错误数值。
    """
    if not rows:
        return rows

    # 阶段 A：token 级温和归一化。
    for row in rows:
        if row.get("header"):
            continue
        cells = row.get("cells")
        if not cells:
            continue
        for col in _DECIMAL_NUMERIC_COLS:
            if col >= len(cells):
                continue
            before = cells[col]
            after, changed = _normalize_decimal_token(before)
            if changed:
                cells[col] = after
                log("decimal fixed col=%d row=%s from=%r to=%r"
                    % (col, row.get("key") or "?", before, after))

    # 阶段 B：按列统计主签名，再对纯数字串插点。
    for col in _DECIMAL_NUMERIC_COLS:
        column_values = [
            row["cells"][col]
            for row in rows
            if not row.get("header")
            and row.get("cells")
            and col < len(row["cells"])
        ]
        signature = _dominant_decimal_signature(column_values)
        if signature is None:
            continue
        int_len, frac_len = signature
        total_len = int_len + frac_len
        for row in rows:
            if row.get("header"):
                continue
            cells = row.get("cells")
            if not cells or col >= len(cells):
                continue
            value = (cells[col] or "").strip()
            if not _DECIMAL_INT_RE.match(value):
                continue
            if len(value) != total_len:
                continue
            if _looks_like_plain_integer(value):
                continue
            head = value[:int_len]
            if len(head) > 1 and head.startswith("0"):
                # 插点后整数部分出现多余前导 0（如 00.123），不合理。
                continue
            fixed = value[:int_len] + "." + value[int_len:]
            cells[col] = fixed
            log("decimal fixed col=%d row=%s from=%r to=%r"
                % (col, row.get("key") or "?", value, fixed))
    return rows


def _render_grid(grid, supplement=None, items=None):
    """渲染 6 列网格为文本。

    行内仍用空格拼接；缺失列为空字符串（空位），绝不把数值挤到相邻列，
    让 Dart 侧「从右往左锚定」的列语义对齐能正确还原各列。
    「数据标识」列补 N 与列级小数点补正都是总铜族专有能力：MCGS 的第 3
    列是「单位」、E.co 的第 3 列是「分析结果」，绝不能补 N。
    """
    _, _, rows, family = grid
    flag_col = family.flag_col

    # 安全网：只有表头、没有任何数据行时，绝不输出「仅表头」文本。
    # 有原始 items 可用就回退到 _layout（列结构会乱，但数据行都在，
    # Dart 侧的列语义对齐能兜住）；无 items 时由 _layout_columns 拦截。
    if items is not None and not any(not r["header"] for r in rows):
        log("grid has no data rows, fallback to _layout")
        return _layout(items)

    # 补充网格只填补主网格的空列，绝不覆盖已识别文本（放大可能引入 OCR 错字）。
    if supplement is not None:
        supp_map = {}
        for row in supplement[2]:
            if not row["header"] and row["key"]:
                supp_map.setdefault(row["key"], row["cells"])
        for row in rows:
            if row["header"] or not row["key"]:
                continue
            other = supp_map.get(row["key"])
            if other is None:
                continue
            for col in range(len(family.headers)):
                if flag_col is not None and col == flag_col:
                    continue
                if not row["cells"][col].strip() and other[col].strip():
                    row["cells"][col] = other[col].strip()
                    log("supplement filled col=%d row=%s value=%r"
                        % (col, row["key"], other[col]))

    # 仅总铜族：第 3 列「数据标识」恒为 N，空则补齐（写回 rows 共享）。
    inferred = 0
    if flag_col is not None:
        for row in rows:
            if not row["header"] and not row["cells"][flag_col].strip():
                row["cells"][flag_col] = "N"
                inferred += 1

        # 列级小数点补正：只动数值列，时间列 / N / 表头都不碰。
        # 同样是总铜族专有能力，MCGS / E.co 的数值列语义不同，不参与。
        _fix_decimal_points(rows)

    lines = []
    for row in rows:
        cells = list(row["cells"])
        # 定长 6 列按序拼接，空列不产生 token（空位表达），值不会串列。
        line = " ".join(c.strip() for c in cells if c.strip())
        if line:
            lines.append(line)
    if inferred:
        log("inferred 数据标识=N for %d data rows (constant flag column)"
            % inferred)
    return "\n".join(lines)


def _layout_columns(items, grid=None, supplement=None):
    """列感知布局入口。

    识别到 6 列表头时按列归位并补 N；否则完全退回原始 [_layout] 行为，
    保证 MCGS / E.co 等其他仪器类型不受影响。
    安全网：grid 只有表头、没有任何数据行时，宁可输出格式较乱的旧布局，
    也绝不能一行数据都不返回。
    """
    if grid is None:
        grid = _table_grid(items)
    if grid is None:
        return _layout(items)
    rows = grid[2]
    if not any(not r["header"] for r in rows):
        log("grid has no data rows, fallback to _layout")
        return _layout(items)
    return _render_grid(grid, supplement, items)


def _extract_rapid(result):
    """RapidOCR 返回 (result_list, elapse)，result_list = [[box, text, score], ...]。"""
    items = []
    data = result[0] if isinstance(result, tuple) and result else result
    if data is None:
        return items
    for entry in data:
        try:
            _add_box(items, entry[0], entry[1])
        except (TypeError, IndexError, ValueError):
            continue
    return items


def _extract_paddle(result):
    items = []

    def walk(node):
        if hasattr(node, "get"):
            try:
                texts = node.get("rec_texts")
                polys = node.get("rec_polys")
                if polys is None:
                    polys = node.get("dt_polys")
                if texts is not None and polys is not None:
                    for poly, text in zip(polys, texts):
                        _add_box(items, poly, text)
                    return
            except Exception:  # noqa: BLE001
                pass
        if isinstance(node, (list, tuple)):
            if (
                len(node) == 2
                and isinstance(node[1], (list, tuple))
                and node[1]
                and isinstance(node[1][0], str)
                and isinstance(node[0], (list, tuple))
                and node[0]
                and isinstance(node[0][0], (list, tuple))
            ):
                _add_box(items, node[0], node[1][0])
                return
            for child in node:
                walk(child)

    if hasattr(result, "__iter__") and not isinstance(
        result, (str, bytes, dict)
    ):
        try:
            result = list(result)
        except Exception:  # noqa: BLE001
            pass
    walk(result)
    return items


def _build_rapid():
    log("build backend rapid: importing rapidocr_onnxruntime")
    from rapidocr_onnxruntime import RapidOCR

    engine = RapidOCR()
    log("build backend rapid: OK")
    return "rapid", engine


def _build_paddle():
    from paddleocr import PaddleOCR

    models = os.environ.get("PADDLEOCR_MODEL_DIR") or os.path.join(
        _base_dir(), "models"
    )
    extra = {}
    if os.path.isdir(models):
        for name in ("det", "rec", "cls"):
            path = os.path.join(models, name)
            if os.path.isdir(path):
                extra[name + "_model_dir"] = path
    try:
        return "paddle", PaddleOCR(
            lang="ch",
            use_doc_orientation_classify=False,
            use_doc_unwarping=False,
            use_textline_orientation=False,
            **extra,
        )
    except TypeError:
        pass
    try:
        return "paddle", PaddleOCR(lang="ch", show_log=False, **extra)
    except TypeError:
        return "paddle", PaddleOCR(
            use_angle_cls=True, lang="ch", show_log=False
        )


def _build_engine():
    forced = os.environ.get("OCR_ENGINE_BACKEND", "auto").strip().lower()
    log("build engine forced=%s" % forced)
    if forced == "rapid":
        order = [_build_rapid]
    elif forced == "paddle":
        order = [_build_paddle]
    else:
        order = [_build_rapid, _build_paddle]

    errors = []
    for factory in order:
        try:
            return factory()
        except Exception as e:  # noqa: BLE001
            errors.append("%s: %s" % (factory.__name__, e))
            log("backend %s failed: %s\n%s" % (
                factory.__name__, e, traceback.format_exc()
            ))
    raise RuntimeError("; ".join(errors) or "未找到任何可用 OCR 后端")


def _read_image(path):
    """用 imdecode 读取图片（兼容中文路径）；失败再退回 cv2.imread。

    仅用于「温和预处理」的裁切放大；任何失败都返回 None，主识别流程不受影响。
    """
    try:
        import cv2
        import numpy as np

        buf = np.fromfile(path, dtype=np.uint8)
        img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
        if img is not None:
            return img
    except Exception as e:  # noqa: BLE001
        log("read image (imdecode) failed: %r" % (e,))
    try:
        import cv2

        return cv2.imread(path)
    except Exception as e:  # noqa: BLE001
        log("read image (imread) failed: %r" % (e,))
        return None


def _maybe_shrink_for_ocr(img):
    """超大裁剪图条件缩放（纯函数，只调尺寸，绝不改变色彩 / 对比度）。

    [img] 为 [_read_image] 读到的 BGR ndarray，或 None（读取失败）。
    - None -> 返回 None，调用方回退到文件路径识别，绝不中断主流程。
    - 宽度 <= [_LARGE_IMAGE_MIN_WIDTH] -> 原样返回 [img]（同一对象），表示
      「不触发缩放」，调用方据此仍走文件路径识别，正常尺寸图零回归。
    - 宽度 > 阈值 -> 用 INTER_AREA 缩到 [_LARGE_IMAGE_SCALE] 并返回新
      ndarray；INTER_AREA 在缩小时抑制振铃，比 INTER_CUBIC 更不容易糊掉
      小号数字。仅写一条文件日志，绝不写 stdout。

    注意：只做尺寸缩放。实跑证明 CLAHE / 锐化虽能找回个别数值，却会让
    表头识别整体失效（family=None、rows=0），因此绝不引入任何对比度 /
    直方图 / 边缘增强处理。返回对象是否为 [img] 本身，即调用方判断「是否
    真的发生了缩放」的依据。
    """
    if img is None:
        return None
    try:
        import cv2

        height, width = int(img.shape[0]), int(img.shape[1])
        if width <= _LARGE_IMAGE_MIN_WIDTH:
            return img
        small = cv2.resize(
            img, None,
            fx=_LARGE_IMAGE_SCALE, fy=_LARGE_IMAGE_SCALE,
            interpolation=cv2.INTER_AREA,
        )
        log("image downscaled %dx%d -> %dx%d (width > %d)"
            % (width, height, int(small.shape[1]), int(small.shape[0]),
               _LARGE_IMAGE_MIN_WIDTH))
        return small
    except Exception as e:  # noqa: BLE001
        # 缩放失败也必须回退到原图，绝不让一张图拖垮整条识别链路。
        log("image downscale failed, keep original: %r" % (e,))
        return img


def _table_roi(grid, shape):
    """由主网格推导表格 ROI（裁掉左侧菜单 / 上下按钮），供放大补识别使用。"""
    height, width = int(shape[0]), int(shape[1])
    centers, header_cy, rows = grid[0], grid[1], grid[2]
    # 第一列（时间）比其余列更宽，用首/末列各自的间距做外扩，
    # 避免用中位间距把日期左侧裁掉（会识别成 '26-11-03 ...'）。
    first_gap = max(1.0, centers[1] - centers[0])
    last_gap = max(1.0, centers[-1] - centers[-2])
    x0 = max(0, int(centers[0] - 0.62 * first_gap))
    x1 = min(width, int(centers[-1] + 0.75 * last_gap))
    data_cys = [row["cy"] for row in rows if not row["header"]]
    # 用表格自身的行间距推导上下留白：约 1.15 倍行距，恰好把表头上方与
    # 末行下方的文字完整纳入，且裁掉标题栏/底部按钮。比按整图高度取比例
    # 更贴合表格密度（实测不同留白会改变放大后网格，导致个别单元格漏检）。
    pitch = _median([data_cys[i + 1] - data_cys[i]
                     for i in range(len(data_cys) - 1)]) if len(data_cys) > 1 else 0.0
    margin = max(24, int(1.15 * pitch)) if pitch > 0 else max(24, int(0.06 * height))
    y0 = max(0, int(header_cy - margin))
    y1 = min(height,
             int((max(data_cys) if data_cys else header_cy) + margin))
    return x0, y0, x1, y1


def _supplement_table(engine, image_path, grid):
    """温和预处理：裁出表格 ROI 后 1.5x (INTER_CUBIC) 放大再识别，返回补充网格。

    - 不传任何 det_* 参数：rapidocr_onnxruntime 的 UpdateParameters 在传了
      det_* 却没传 det_model_path 时会 KeyError('model_path')，且打包后
      site-packages 的绝对路径不存在；不传 det_* 天然规避该 bug。
    - RapidOCR 默认 limit_type='min' / limit_side_len=736：大图不会被内部
      下采样，因此 1.5x 放大能真实提升小号数字的检出分辨率。
    - 实测整图放大反而会引入错字（小数点点丢、中文被拆），故只对表格 ROI
      放大，且补充网格仅用于填补主网格空列，绝不覆盖主网格已识别文本。
    """
    try:
        import cv2

        img = _read_image(image_path)
        if img is None:
            log("supplement skipped: cannot read image")
            return None
        x0, y0, x1, y1 = _table_roi(grid, img.shape)
        if x1 - x0 < 200 or y1 - y0 < 150:
            log("supplement skipped: ROI too small %r" % ((x0, y0, x1, y1),))
            return None
        crop = img[y0:y1, x0:x1]
        up = cv2.resize(crop, None, fx=1.5, fy=1.5,
                        interpolation=cv2.INTER_CUBIC)
        log("supplement ROI=%r upscaled=%r" % ((x0, y0, x1, y1), up.shape))
        started = time.time()
        output = engine(up)
        items = _extract_rapid(output)
        log("supplement done in %.1fs boxes=%d"
            % (time.time() - started, len(items)))
        return _table_grid(items)
    except Exception as e:  # noqa: BLE001
        log("supplement failed: %r\n%s" % (e, traceback.format_exc()))
        return None


def _recognize(kind, engine, image_path):
    log("recognize start backend=%s path=%r" % (kind, image_path))
    if kind == "rapid":
        # 四角透视裁剪会把图放大约 1.45 倍，RapidOCR 内部下采样后小号数字
        # 被糊没。仅宽度 > 阈值时先缩到 0.75 再识别；正常尺寸图 / 读图失败
        # 完全沿用原文件路径交给 engine（ocr_input 保持 image_path），
        # 保证既有识别链路零回归。engine(ndarray) 已由 _supplement_table 验证。
        ocr_input = image_path
        did_shrink = False
        base_img = _read_image(image_path)
        if base_img is not None:
            shrunk = _maybe_shrink_for_ocr(base_img)
            # _maybe_shrink_for_ocr 未触发缩放时返回同一对象 base_img，
            # 返回新对象才代表真的缩小了（此时才改用 ndarray）。
            if shrunk is not None and shrunk is not base_img:
                ocr_input = shrunk
                did_shrink = True
        output = engine(ocr_input)
        items = _extract_rapid(output)
        log("recognize rapid raw items=%d shrunk=%s" % (len(items), did_shrink))
        grid = _table_grid(items)
        # 放大补识别（_supplement_table）是总铜 / 总磷屏的既有能力，专为
        # 小号数字漏检设计。MCGS / E.co 是新支持的表头族，其数值列语义不同，
        # 实跑发现 ROI 放大补识别会往个别空列填入与其它行不一致的孤立
        # token（如 E.co 某行分析结果列多补一个「未检出」），反而不稳定。
        # 故仅对总铜族（flag_col 非空）启用：新族输出稳定，总铜族零回归。
        # 只有表头、没有数据行时也不必补识别（ROI 无数据行可推导）。
        # 缩放后 grid 坐标基于缩小图，而 _supplement_table 读的是原图，
        # 两者坐标不同源，故缩放图一律跳过补识别（主识别已找回小字）。
        need_supplement = (
            grid is not None
            and not did_shrink
            and grid[3].flag_col is not None
            and any(not r["header"] for r in grid[2])
        )
        if need_supplement:
            supplement = _supplement_table(engine, image_path, grid)
        else:
            supplement = None
        text = _layout_columns(items, grid, supplement)
    else:
        result = (
            engine.predict(image_path)
            if hasattr(engine, "predict")
            else engine.ocr(image_path, cls=True)
        )
        items = _extract_paddle(result)
        log("recognize paddle raw items=%d" % len(items))
        text = _layout_columns(items)
    # 最终安全网：无论哪条分支，只要输出里没有任何含时间/数字的数据行
    # （例如只剩表头），就退回原始 _layout，宁可格式乱也不丢数据行。
    if not _has_data_line(text):
        log("recognize result has no data line, fallback to _layout")
        text = _layout(items)
    log("recognize done chars=%d text=%r" % (len(text), text[:800]))
    return text


def _run_once(image_path):
    """一次性识别：输出一行 JSON 后退出。"""
    log("ONCE start path=%r exists=%s" % (image_path, os.path.isfile(image_path)))
    if not os.path.isfile(image_path):
        _emit({"status": "error", "message": "图片不存在: %s" % image_path})
        return
    kind, engine = _build_engine()
    text = _recognize(kind, engine, image_path)
    _emit({"status": "success", "text": text})


def _run_daemon():
    try:
        kind, engine = _build_engine()
        log("engine ready backend=%s" % kind)
    except Exception as e:  # noqa: BLE001
        log("ENGINE BUILD FAILED: %s\n%s" % (e, traceback.format_exc()))
        _emit({"status": "error", "message": "模型加载失败: %s" % e})
        return
    _emit({"status": "ready", "backend": kind})
    log("ready emitted, entering stdin loop")

    while True:
        line = sys.stdin.readline()
        log("stdin line=%r" % (line,))
        if not line:
            log("stdin EOF, exit")
            break
        image_path = line.strip()
        if image_path == "exit":
            log("exit command, exit")
            break
        if not image_path:
            continue
        try:
            if not os.path.isfile(image_path):
                log("image missing: %r" % image_path)
                _emit({"status": "error", "message": "图片不存在: %s" % image_path})
                continue
            _emit({"status": "success", "text": _recognize(kind, engine, image_path)})
        except Exception as e:  # noqa: BLE001
            log("recognize EXCEPTION: %s\n%s" % (e, traceback.format_exc()))
            _emit({"status": "error", "message": str(e)})


def main():
    log("=== ENGINE START ===")
    log("argv=%r" % (sys.argv,))
    log("cwd=%r executable=%r MEIPASS=%r" % (
        os.getcwd(), sys.executable, getattr(sys, "_MEIPASS", None)
    ))
    log("stdout=%r stdin=%r stderr=%r" % (
        getattr(sys, "stdout", None),
        getattr(sys, "stdin", None),
        getattr(sys, "stderr", None),
    ))
    _setup_stdio()

    if len(sys.argv) >= 3 and sys.argv[1] == "--once":
        try:
            _run_once(sys.argv[2])
        except Exception as e:  # noqa: BLE001
            log("ONCE FAILED: %s\n%s" % (e, traceback.format_exc()))
            _emit({"status": "error", "message": str(e)})
        return

    _run_daemon()


if __name__ == "__main__":
    main()
