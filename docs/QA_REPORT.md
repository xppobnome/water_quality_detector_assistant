# 水质检测仪助手 — QA 审查与独立回归验证报告

> QA：严过关（Edward） | 审查方式：静态审查 + 纯 Dart/Python 独立实跑（本机 `flutter/dart analyze/test` 因 `CreateFile failed 231` 不可用）
> 版本指纹：`python/ocr_engine.py` 1281 行 / 51981 bytes / `md5 217a507a5d9df30d3c27c153684e3448` / 2026-11-08 16:57:43
> `lib/` 76 个 dart 文件 + `test/` 2 个 = **78 个文件**

## 0. 审查前提（重要，避免误读本报告的结论）

1. **工作区是会话中持续更新的实时版本**。我第一轮读到的是旧快照（36 个 dart 文件、ML Kit 单识别器、无浮窗/裁剪/`python/ocr_engine.py`），后续核实发现磁盘已被工程师并发更新为 76 个 dart 文件的完整增量版本。**本报告所有结论均基于当前磁盘重新读取后的代码**，旧快照结论全部作废。
2. 最新任务（条件缩放风险评审）派发时工程师仍在改文件：我第一次读 `ocr_engine.py` 为 1214 行、无缩放实现；约 2 小时后重读为 **1281 行 / 16:57:43**，已包含 `_maybe_shrink_for_ocr` + `did_shrink`。故「实现尚未落地」这一中间判断已作废，下文按**已落地版本**评审。
3. **不要橡皮图章**：本报告列出 3 个 P1 与 8 个 P2，其中 P1-1 会直接使本轮「手机端数字不准」修复失效，已用 Dart 实跑坐实。

### 0.1 三条静态基线命令的真实输出

```
$ dart format lib test
Formatted 78 files (0 changed) in 3.81 seconds.

$ python .tmp_ocr_test/analyzer_legacy.py
VERSION: {'id': '1', 'result': {'version': '1.40.1'}}
ANALYSIS IDLE: False
FILES CHECKED: 78 / 78 (missing 0)
ERRORS (0)
WARNINGS (0)

$ python .tmp_ocr_test/analyzer_probe.py   # 取关键行
   ERROR return_of_invalid_type A value of type 'String' can't be returned from the function 'broken' because it has a return type of 'int'.
DETECTED: True
VERDICT: analyzer is live, 0 errors is trustworthy
```

> 注：`dart run <脚本>` 会触发 native assets build hooks，同样撞 `CreateFile failed 231`；改用 `dart .tmp_ocr_test/xxx.dart`（直接执行、走 `.dart_tool/package_config.json`）**实跑成功**，下列 Dart 探针均为真跑。
> `python -m py_compile python/ocr_engine.py` → `py_compile OK`。
> 负向 grep（lib/ + test/ 全库）`anchorKey / onPreview / anchorBottomInContent / isAnchorScrolledOut / _thumbnailsKey / _evaluateVisibility / _dismissed / _imageScaleBase / _onImageScaleUpdate / "_pointers >= 2" / _resolveExecutable / ScrollController.addListener` → **全部 0 匹配**。

---

## 1. 最新任务：条件缩放方案独立风险评审（1~5）

### 1.1 坐标一致性 — **无风险（工程师已补做守卫）** ✅

- 主识别 `python/ocr_engine.py:1160-1170`：`did_shrink=True` 时 `ocr_input = shrunk`（0.75 缩放后的 ndarray），`engine(ndarray)`；否则保持 `image_path`。
- 补识别 `_supplement_table(engine, image_path, grid)`（`:1116-1150`）内部 `_read_image(image_path)` **重新解码原图**，`_table_roi(grid, img.shape)`（`:1134`）的 shape 来自原图。若缩放后仍调补识别，grid 坐标是缩小图坐标系、shape 是原图 → ROI 裁剪整体偏移，补网格列语义可能错位。
- **但** `ocr_engine.py:1182-1187` 的 `need_supplement` 已显式加入 `and not did_shrink`，注释（`:1180-1181`）也写明「缩放图一律跳过补识别」。**缩放与补识别互斥，坐标系不共系的风险被消除**。
- 补充结论（team-lead 追问的另外两点）：
  - 补网格与主网格**本来就不共系**（补识别是 ROI 裁剪 + 1.5x `INTER_CUBIC`），但 `_render_grid` 的 `supp_map` 按 `row["key"]`（`_hour_key`，HH:MM 文本，`:538-541`）匹配而非按坐标匹配（`:840-856`），所以坐标系差异本身不会填错列；真正会填错的是 ROI 裁错区域导致补网格列中心偏移 —— 已被 `not did_shrink` 一并规避。
  - `_header_anchors` / `_SkewModel` / `_time_column_center` 全部在 `_table_grid(items)` 内使用同一份 `items` 坐标，内部自洽（`:586-669`）。
  - **`outW/outH` 与 `_warpPixels` 不受影响**：Dart 侧 `image_crop_service.dart:237-253` 的透视输出尺寸在裁剪落盘时已确定，Python 缩放作用于**已落盘的 PNG**，两者不同进程、不同阶段，不存在反馈。

### 1.2 阈值 2000px — **风险，需工程师补做** ⚠️【中】

- `ocr_engine.py:158` `_LARGE_IMAGE_MIN_WIDTH = 2000`，`:1076` `if width <= _LARGE_IMAGE_MIN_WIDTH: return img`（**严格 `<=`，硬边界**）。
- Dart 侧 `image_crop_service.dart:237-240`：`outW = ((上边长+下边长)/2).round()`、`clamp(1, 3000)` —— 输出宽度是**连续值**，必然横跨 2000：`1999`（不缩放）与 `2001`（缩到 1500）仅差 2px 却走完全不同的识别链路，结果不连续。
- 只判 `width` 会漏掉**高瘦图**（`outW=1500, outH=2900`）——同样被 RapidOCR 内部 `limit_side_len=736` 下采样糊掉却不触发。
- **更实质的组合风险**：总铜族是唯一启用补识别的族（`flag_col` 非空）。若某张总铜图经四角裁剪后宽度 >2000 触发缩放，则会**同时失去补识别**（`not did_shrink`）；「缩放 + 总铜族无补识别」这一组合**未被任何实测覆盖**，可能漏检小号数字。
- 建议：① 改按 `max(width, height)` 阈值；② 更稳的判据是按**相对原图的放大倍率**（`width / src_width > 1.2`）或「四角裁剪产物（PNG 且尺寸≠原图）」，避免硬边界；③ 补一组「总铜图 >2000 触发缩放」的端到端样本。

### 1.3 总铜图缩 0.75 多出 1 行 — **需工程师补做（无法实跑，无样本图）**

- 本方案阈值 2000，1920 宽总铜图不触发（`:1076` `<=`），**本方案下不会复现 13 行**。
- 代码级推断（供工程师用真实 COPPER 样本验证）：缩放后小字检出率提高，且 `_layout` 的行聚类 `tolerance = max(6.0, max_height * 0.6)`（`ocr_engine.py:262`）随框高同比缩小，原本被合并的一行可能被拆成两行；或底部状态栏/按钮文字（常含 HH:MM 系统时间 + 数字）被识别出，通过 `_table_grid` 的「非表头行须含时间锚点且 ≥2 个数值列」过滤（`:666`）。表头以上的标题栏由 `:643` `cy < header_cy - 20` 剔除，故**多出行更可能是底部 UI 噪声或拆分行**。
- 若将来阈值下调使 1920 宽总铜图触发缩放：该伪行进入输出文本 → Dart `_parseTotalCopper`（`ocr_parser.dart:383`）从右往左锚定 4 个数值 → 生成一条错误 `WaterQualityRow` → 污染 Excel 导出与去重结果。

### 1.4 协议与降级 — **无风险（有一处小缺口）** ✅

- `_maybe_shrink_for_ocr`（`:1054-1090`）：`img is None` → 返回 None；`cv2` 不可用 / `resize` 抛异常 → `:1087-1090` catch 后 `return img`（同一对象）→ 调用方 `shrunk is not base_img` 为假 → `ocr_input` 保持 `image_path` → **不中断识别**。
- `--once` 单行 JSON：`_emit`（`:229-233`）`json.dumps` + `sys.stdout.write(line+"\n")`；`log()`（`:201-212`）只写文件；`_setup_stdio`（`:215-226`）只 `reconfigure`，**stdout 纯净**。
- 三层安全网完整：`_layout_columns` grid=None / 无数据行回 `_layout`（`:891-899`）、`_render_grid` 无数据行回 `_layout`（`:834-836`）、`_recognize` 最终 `_has_data_line` 回 `_layout`（`:1202-1206`）。
- **小缺口（P2）**：`engine(ocr_input)` 自身抛异常时，`_run_once` 会被 `main()` 捕获后 `_emit error`、常驻模式被 `_run_daemon` 捕获后 `_emit error` —— 是「本次识别失败」而非「回退原图重试」。建议加一次 `engine(image_path)` 兜底重试。
- 另：`_recognize:1162` **无条件** `_read_image(image_path)`，正常尺寸图也要全图解码一次（1920×1078×3 ≈ 6MB）再丢弃，常驻模式连发多图有额外 CPU/内存开销。建议先用 `IMREAD_REDUCED_COLOR_2` 读头判宽。且缩放只在 `kind == "rapid"` 分支生效，强制 `OCR_ENGINE_BACKEND=paddle` 时方案不生效（`:1193-1201`）。

### 1.5 Dart 侧影响 — **无风险** ✅

- 输出格式未变：`_render_grid:874` `" ".join(c.strip() for c in cells if c.strip())`，每行字段单空格分隔、空列不占位；Dart 侧 `ocr_parser.dart` 的「从右往左锚定」（`:104/:221/:294/:380/:442`）与 `table_structure_detector.dart` 判型均按**文本**，不依赖坐标/尺寸。`lib/utils/ocr_parser.dart` **无需配合改动**。
- 唯一注意：缩放改变识别框 → 可能改变每行可见列数 → token 数变化会影响从右往左锚定，属识别质量变化，需真机回归，非格式兼容问题。

---

## 2. 第四条收窄角度（C / D / E / F）

### C. 关闭小窗后 AppBar 按钮状态同步 — **FAIL（P2，状态残留）** ❌

- 链路本身正确：`_showFloating` 初值 false（`image_to_excel_page.dart:34`）→ AppBar `IconButton` 在 `provider.imagePaths.isEmpty` 时 `onPressed: null` 置灰（`:108-110`）→ `visible: _showFloating`（`:116`）→ `FloatingImageHost` 内 `if (widget.visible && widget.imagePaths.isNotEmpty)`（`:139`）→ 小窗关闭按钮 `onTap: widget.onClose`（`floating_image_window.dart:543`）→ `onClose: () => setState(() => _showFloating = false)`（`:117`）。`calculation_page.dart:30/165/178-179` 同构。
- **残留路径**：`image_to_excel_page.dart:232` 的「清空图片」按钮调用 `provider.clearImages()`，**不复位 `_showFloating`**。用户开着小窗点清空 → `imagePaths` 变空 → 小窗因 `imagePaths.isNotEmpty` 为假被移除、按钮置灰，但 `_showFloating` 仍为 **true** → 之后重新拍照/选图，小窗**未经用户点击就自动出现**，违反「AppBar 手动开关」语义，且按钮图标仍是「已激活」态。
- 修复：`clearImages()` 的 `onPressed` 同时 `setState(() => _showFloating = false)`，或在 `didUpdateWidget`/`build` 中当 `imagePaths.isEmpty` 时把 `_showFloating` 同步复位。

### D. `Listener` 手势边界 — **部分 FAIL（P2）** ⚠️

- 正向：`_activePointers`（`:203`）、`onPointerDown` 不 setState（`:325-330`）、`HitTestBehavior.translucent`（`:486`）、`onPointerUp/Cancel` 清理（`:360-368`）、`_onPageChanged` 重置缩放与 `_lastPinchDistance`（`:398-406`）、`pinchScale` 纯函数（`table_column_width.dart:64-73`）——全部符合方案。
- **边界 1（3 指 → 2 指）**：`_pinchDistance()`（`:371-374`）取 `_activePointers.values` 的**前两个**；3 指按着时若抬起的是第 1/2 指之一，`_onPointerUp` 只在 `length < 2` 时清 `_lastPinchDistance`（`:362`），3→2 时**不清**，而剩余两指组合已变 → 下一帧距离比跳变，产生突兀缩放。建议：只要触点集合发生增减（无论是否 ≥2）就重置 `_lastPinchDistance = null`。
- **边界 2（单指平移 ↔ 双指缩放切换）**：`onPanUpdate: (_activePointers.length < 2 && zoomed) ? _panImage : null`（`:572`）是 build 期求值的闭包，而 `_onPointerDown` 刻意不 setState → 第二指按下到第一帧 `_onPointerMove` 触发 setState 之间，`onPanUpdate` 仍是旧的 `_panImage`，短窗口内平移与缩放并发。`onPointerMove` 一旦 setState 即恢复正确，影响有限但真实存在。
- **边界 3（切图时仍按两指）**：`_onPageChanged` 只清 `_lastPinchDistance`，不清 `_activePointers`；放大态用 `NeverScrollableScrollPhysics`（`:563`）但左右箭头 `onTap` 仍可调 `_pageController.previousPage/nextPage`（`:607/:620`），此时会把 scale 复位而两指仍按着 → 下一帧重新起算缩放，语义混乱。

### E. 手柄方向语义（clamp 后反直觉）— **FAIL（P2）** ❌

- `resizeWindowRect`（`:65-88`）：`delta = fromLeft ? -dx+dy : dx+dy`，`newLeft = fromLeft ? rect.right - newWidth : rect.left`；`_resize` 最后 `_rect = _clampRect(resized)`（`:288`）。`_clampRect`（`:246-252`）只夹 `left/top`，**width/height 不变**。
- 左下角手柄（fromLeft=true，承诺「右上角锚点恒定」）在窗口贴**右边缘**向外放大时，`newLeft = rect.right - newWidth` 可能为负 → 被 clamp 到 0，而 width 不变 → `right = 0 + newWidth > 原 rect.right`，**右边界向右移动**，右上角锚点漂移；视觉上「向外拖」变成整体右移，与文档（`:58-63`）承诺不符。右下角手柄同理在贴左边界时会有对应的镜像问题（影响较小）。
- 修复：clamp 时按锚点类型约束 `newWidth <= rect.right`（fromLeft）或 `newWidth <= bounds.width - rect.left`（fromRight），或 clamp 后同步收缩 width 而非仅平移 left。

### F. Python 补正是否会把合法数值改坏 — **FAIL（P1-3 + P2）** ❌

真实日志 7 行样本 **10/10 PASS**（`4 6659→4.6659`、`4 6687→4.6687`、`44942→4.4942`、`04669→0.4669`、`04098→0.4098`、`2022. 950→2022.950`、`3286. 85→3286.85`；`3289.70/3283.10/3279.72` 保持 2 位小数；**时间列 0 改动、N 列 0 改动**）。但攻击性输入发现：

```
--- 攻击：一个 cell 含多个数值
    CHANGED col=1 '1234 5678' -> '1234.5678'      ← 两个独立数值被合并成一个
--- 攻击：前导零整数 / 与主签名同位的纯整数
    CHANGED col=1 '01234'   -> '0.1234'
    CHANGED col=4 '1370550' -> '1370.550'
--- 60% 边界
    3/5 主签名(4,3) 恰 60% -> dominant=(1, 4)
    2/5 主签名(4,3) 仅 40% -> dominant=(1, 1)     ← 短签名也会成为主签名
--- 保守性（短纯整数 / 多个小数点 / 全列无小数点）
    改动总数 = 0                                    ← PASS
```

- **P1-3**：`_DECIMAL_SEP_RE = re.compile(r"[\-:,·。 .]+")`（`:160`）把**空格**也当分隔符。阶段 A `_normalize_decimal_token`（`:702`）会把 `"1234 5678"` 折叠成 `"1234.5678"`（合法小数形态），**把两个独立数值合并成一个**，属确定性数据错误。修复：阶段 A 只在「原串去掉分隔后仅构成一组 `^\d+\.\d+$` 且不存在第二个独立数字段」时生效；含空格的 token 要求两侧位数与主签名匹配、总长等于主签名总长。
- **P2**：阶段 B（`:796-816`）无法区分「OCR 丢了小数点的数」与「合法纯整数」：`01234`、`1370550` 均被强制插点。这是本轮 `44942→4.4942` 所依赖的设计取舍，不要求推翻，但需工程师确认业务上数值列不会出现合法纯整数，并建议加「该列存在纯整数样本时放弃插点」的保守条件。
- 60% 边界：3/5 与 2/5 均返回非 None 主签名（短签名 `(1,1)` 由多数简写小数决定）；因 `_looks_like_plain_integer`（`:740-742`）保护 len≤4 非前导零整数，实际未造成误改，但主签名可被简写行主导，需留意。

---

## 3. 第二条 A–H 独立回归结论

| 项 | 结论 | 依据 |
| --- | --- | --- |
| **A** fixOcrDigits 破坏通道字母 | **PASS** ✅ | `lib/utils/ocr_digits.dart:20` `^[A-Za-z]$` 单字母直接返回、`:17` 含中文直接返回。Dart 实跑：`A/B/C/A通道/大肠埃希氏菌B/总大肠菌群A/菌落总数C/N/未检出/MPN/L/18:00:00/2026-11-03` **全部原样**；`parseOcrText('... B 未检出 0.100 0.050', eco)` → `channel=大肠埃希氏菌B`，整行未跳过。team-lead 的头号怀疑被证伪。唯一边界：`AB -> 48`（多字母无保护），不影响合法通道但可能把文本噪声变数值干扰列定位（P2-6）。 |
| **B** 双识别器合并丢行/重复 | **FAIL（P1-1 / P1-2）** ❌ | 见 §3.1 详述，已 Dart 实跑坐实。 |
| **C** `resolvedExecutable` 改名 | **PASS** ✅ | 负向 grep `_resolveExecutable` **0 匹配**；`ocr_service.dart:233/268/455/572` 全用新名；`initEngine()`（`:256-275`）内 `:268` 已同步；`settings_page.dart:368/416` 亦用新名；`:592-603` 向上 6 级回溯存在。 |
| **D** CMake `OPTIONAL` 语法 | **PASS** ✅ | `windows/CMakeLists.txt:109` `OCR_ENGINE_DIR` 定义在 `install` 之前且**在任何 if 块之外**；`:112-114` `install(DIRECTORY ... COMPONENT Runtime OPTIONAL)` 为 CMake 合法关键字组合（通用选项顺序不限）。**实证**：`build/windows/x64/cmake_install.cmake:294` 已生成 `file(INSTALL DESTINATION ... TYPE DIRECTORY OPTIONAL FILES "…/windows/ocr_engine/")`，证明 configure 成功解析。 |
| **E** 首页溢出 | **PASS（估算）** ✅ | `home_page.dart:224` padding 10×2=20、icon 44（`:234-240`）、`SizedBox 8`、标题 fontSize 13 行高≈16~18、`SizedBox 4`、副标题 fontSize 10 两行≈24~28（`:253-260` `Flexible` + `maxLines:2` + ellipsis）、`mainAxisSize.min`（`:230`）。合计 **122~126 < 140.4**，且 `Flexible` 保证压缩而非溢出。 |
| **F** 全选/反选闭环 | **PASS**（另有 P2） ✅ | 三步：初始 `TableSelection()` → `isAllSelected=true`（`image_to_excel_provider.dart:278-281`）→ 表头 `onSelectAll(!allSelected)=false`（`editable_result_table.dart:117`）→ `setAllSelected(false)` 生成 `TableSelection(noneSelected:true)`（`:327-331`）→ `isRowSelected` 恒 false（`:77-80`）→ `apply` 返回 0 行（`:98-99`）；再点 → `isAllSelected=false` → 传 `true` → 恢复 `TableSelection()` 全选。**语义正确，无矛盾**（`noneSelected` 优先于 `selectedRowIds`，且 `setAllSelected` 每次都新建对象）。P2-5：`setAllSelected` 新建对象会丢弃 `selectedColumns`/`excludedCells`，反选连带清空列勾选与单元格排除。 |
| **G** 四角裁剪 | **PASS** ✅ | `_applyCorner` 不存在（工程师重构为 `_onCornerDrag`），但 `croppable_image.dart:136-178` 逐字带入其余三个 `Offset`、只 `clamp` 被拖角坐标（`:154-157`）、拖拽路径**不调 `CropQuad.clamp()`**（`clamp` 只在 `:89/:97/:219` 的 init/reset）；`_emit()`（`:126`）传归一化 `CropQuad`；`_onPan`（`:182-212`）四点加同一偏移，宽高恒定。`CropPage:145` `onChanged → _quad`、`:83` `cropQuad(imagePath, quad)`、`image_crop_service.dart:229-230` `o.dx*w, o.dy*h` —— **归一化坐标系一致**。 |
| **H** 时间列缺日期 | **PASS** ✅ | Dart 实跑 `parseOcrText('2026-11-03 18:00:00 28.2945 0.9329 N 1370.550 3570.500', totalCopper)` → `rows=1`、`cells[时间]='2026-11-03 18:00:00'`、`sampleDate=2026-11-03`、`sampleTime=18:00:00`，5 个数值**无错位**（数据结果 28.2945 / 吸光度 0.9329 / 标识 N / 当前值 1370.550 / 空白值 3570.500）。`_indexOfTime`（`:643-650`）改用 `_isTimeLikeToken`（`:501-505`，正则要求末尾 `\d{1,2}:\d{2}`），`'2026-11-03'` 不匹配 → 不会把日期误当时间锚点；`_indexOfDate`/`_parseMcgs`/`_parseEco` 仍调同一函数，日期 token 依然可被 `_isNumericCandidate`（`:522-530`）排除，无行为回归。 |

### 3.1 B 项详述（本轮最严重发现）

`MlKitOcrService._merge`（`lib/services/mlkit_ocr_service.dart:120-137`）：

```dart
final headers = cnText.split('\n').where((l) => han.hasMatch(l)).toList();   // 含「所有中文行」
final dataLines = enText.split('\n').where((l) => digit.hasMatch(l)).toList(); // 含「所有数字行」
if (dataLines.isEmpty) return cnText.trim();
return [...headers, ...dataLines].join('\n');
```

「中文行 = 表头行」这一假设**不成立**。三组典型文本走查：

| 组 | cnText 含中文行 | enText 含数字行 | 合并结果 | `detectInstrumentType` |
| --- | --- | --- | --- | --- |
| ① 总铜 | 标题栏、表头（数据行纯数字+N，不含中文） | 数据行 | 表头 + 数据行 ✅ | 命中 `吸光度/数据标识/当前值/空白值` → `totalCopper` ✅ |
| ② E.co | 标题栏、表头、**数据行（`大肠埃希氏菌B` / `未检出` 含中文）** | 数据行（日期+数值） | **数据行出现两次**（中文版在前、拉丁版在后）❌ | 命中 `通道`/通道名 → `eco` ✅（判型本身不受影响） |
| ③ MCGS | 标题栏、表头、**「总大肠杆菌」列为「未检出」时数据行含中文** | 数据行 | 同上重复 ❌ | 命中 `空白对照/测试对照` → `mcgs` ✅ |

**Dart 实跑证据**（把 `_merge` 输出喂给 `parseOcrText`）：

```
=== [5] B 项：_merge 输出「中文行 + 拉丁行」是否产生重复数据行 ===
merged rows=2 warnings=[]
  dedupKey=2024-01-01|10:00|大肠埃希氏菌B channel=大肠埃希氏菌B blank=0.1 detection=0.05 result=未检出
  dedupKey=2024-01-01|10:00|大肠埃希氏菌B channel=大肠埃希氏菌B blank=0.1 detection=0.05 result=未检出
```

→ 两行 `dedupKey` 完全相同，`DedupService.dedup`「保留首次出现」会**保留 cnText 的中文版**（正是中文模型数字识别不准的那份），丢弃拉丁准确行。**本轮「手机端数字不准」修复的核心目标被直接抵消**。

另 **P1-2**：回退条件仅 `dataLines.isEmpty`。若拉丁识别器只识别出系统时间/页码/仪器编号等 1 行数字、真实数据行全丢，`dataLines` 非空 → **不回退**，输出只有表头+噪声，数据全丢。

修复建议（交工程师）：
1. `headers` 只保留**真表头行** —— 用 `detectInstrumentType` 的表头关键词集合（吸光度/数据标识/当前值/空白值/通道/分析结果/空白对照/测试对照/总大肠杆菌/单位/采样日期…）判定，而非「含中文」；或按行 y 坐标只取表头所在行。
2. 数据行一律取拉丁版；合并后按「采样日期+采样时间+通道」key 去重，**优先保留拉丁行**。
3. 回退条件改为「`dataLines` 中不含任何时间锚点行」或「数据行数 < 表头行对应的最小期望行数」时回退 `cnText`。

---

## 4. 首轮任务：6 条业务规则 + 测试覆盖（基于当前磁盘代码复核）

| # | 规则 | 结论 | 依据 |
| --- | --- | --- | --- |
| 1 | 吸光度 `ln(空白/检测)*10000`，反向 `ln(检测/空白)`，只用空白/检测，空/非数值/≤0 返回 null 并提示 | **正确** ✅ | `fit_service.dart:10-20`（null/≤0/非有限/ratio 校验齐全，方向按 `blank>=detection`）；`result_validator.dart:11-43` 提供跳过提示；`calculation_provider.dart` 调用前校验。 |
| 2 | 拟合 `y=aX+b`，斜率 a 展示 B、截距 b 展示 A，输出 A/B/R²，两点 R²=1 | **正确** ✅ | `fit_service.dart:25-86` 最小二乘 + `sxx==0`/`syy==0` 退化处理 + `clamp(0,1)`；两点 `ssRes=0 → R²=1`；`calculation_page.dart:495-501` A=intercept / B=slope / R² 展示正确。 |
| 3 | 去重键 `日期\|时间\|通道`，无通道用简称 MCGS/总铜/E.co | **正确** ✅ | `water_quality_row.dart:80-81`；`instrument_type.dart:10-12` 简称正确；`dedup_service.dart:8-18` 保留首次 + 跳过空键。 |
| 4 | 二维码 `WQA\|1.0\|{ip}:{port}\|{token}` | **正确** ✅ | `qr_service.dart:7-9` 构造、`:12-35` 解析（段数/tag/版本/端口范围/token 非空校验）；`constants.dart:20-21` `WQA`/`1.0`。 |
| 5 | E.co 三通道必须分类、不可混算 | **解析层正确 / 计算层未强制** ⚠️ | `ocr_parser.dart:609-618` 三类通道 + 裸 A/B/C 映射正确；`instrument_type.dart` 有 `hasChannel`；**但 `lib/providers/calculation_provider.dart` 全文无 `channel` 字样**，`calculate()` 未按通道校验「空白行 / 含菌行是否同一通道」，用户可跨通道混算且无提示 → P2-7（违反 PRD 用户故事 3）。 |
| 6 | 「是否计算其他值」已取消，不应存在实现 | **正确** ✅ | 全库 grep `是否计算其他值\|计算其他值\|其他值` **0 匹配**。 |

**测试覆盖评估**（`test/widget_test.dart` 348 行 + `test/services_test.dart`）：核心纯函数覆盖较好，但**存在「断言不能捕获回归」的空白**：

- 已覆盖：`CropQuad` 四点独立 / clamp / isValid / toBoundingRect（`widget_test.dart:80-140`）、`pinchScale`、小数点补正、`Workspace` 命名、`detectInstrumentType` 相关、首轮 `FitService`/`DedupService`/`NumberUtils`/`QrService`/`OcrParser` 基础用例。
- **缺失（按优先级）**：
  1. `MlKitOcrService._merge` **零单测** —— 本轮 P1-1 正是它引入的；必须补「中文表头+中文数据行+拉丁数据行」的重复行断言与「enText 只有噪声行」的回退断言。
  2. `_fix_decimal_points` 缺「一个 cell 含多个数值」「合法纯整数」的负向断言（本次实跑已证明会被改坏）。
  3. `fixOcrDigits` 缺 E.co 三通道 A/B/C 与中文通道名的保护断言（虽然实现正确，但回归无护栏）。
  4. `CalculationProvider.calculate` 缺 E.co 跨通道混算的拦截断言。
  5. 吸光度反向 / 退化拟合（单点、全 x 相同、全 y 相同）、去重键 E.co 通道与「总铜」简称、`QrService` 非法端口/空 token、`FileTransferService`/`DiscoveryService` 协议均无覆盖。
- `widget_test.dart:101-111` 的「拖动 tl 时其余三点不变」是**复刻构造方式**而非调用 `_onCornerDrag`，属于「测试自己实现了一遍被测逻辑」，**捕获不到产品代码回归** —— 建议改为把 `_onCornerDrag` 的核心构造抽成纯函数供单测直接调用。

---

## 5. 缺陷清单（需退回工程师）

### P1（阻断，必须修）

| ID | 文件:行号 | 问题 | 复现 / 证据 |
| --- | --- | --- | --- |
| **P1-1** | `lib/services/mlkit_ocr_service.dart:126-136` | `_merge` 把「含中文的所有行」当表头，E.co/MCGS 数据行含中文 → 中文版与拉丁版同时输出，`DedupService` 保留首次（数字不准的中文行），本轮手机端数字修复失效 | Dart 实跑 `merged rows=2`，两行 `dedupKey` 相同，见 §3.1 |
| **P1-2** | `lib/services/mlkit_ocr_service.dart:135` | 回退条件仅 `dataLines.isEmpty`；拉丁识别器只出 1 行噪声数字时真实数据行全丢且不回退 | 构造 `enText='系统时间 2026-11-03 18:00'` + 表头即可复现 |
| **P1-3** | `python/ocr_engine.py:160, 702` | `_DECIMAL_SEP_RE` 含空格，阶段 A 把 cell 内两个独立数值合并成一个小数 | 实跑 `'1234 5678' -> '1234.5678'` |

### P2（建议修 / 需确认）

| ID | 文件:行号 | 问题 |
| --- | --- | --- |
| P2-1 | `python/ocr_engine.py:796-816` | 阶段 B 无法区分「丢小数点的数」与合法纯整数：`01234→0.1234`、`1370550→1370.550`（设计取舍，需确认业务并考虑加保守条件） |
| P2-2 | `lib/pages/image_to_excel_page.dart:34,108,117,232`；`calculation_page.dart:30,165,179` | `clearImages()` 不复位 `_showFloating`，清空后再加图小窗自动出现，违反手动开关语义 |
| P2-3 | `lib/widgets/floating_image_window.dart:360-368, 572, 398-406` | 3指→2指不清 `_lastPinchDistance` 致缩放跳变；`onPanUpdate` 闭包在 down 不 setState 时滞后；切图不清 `_activePointers` |
| P2-4 | `lib/widgets/floating_image_window.dart:75-87, 246-252, 275-289` | 左下角手柄贴右边缘放大时 `_clampRect` 平移整个矩形，右上角锚点漂移、方向反直觉 |
| P2-5 | `lib/providers/image_to_excel_provider.dart:327-331` | `setAllSelected` 新建 `TableSelection`，反选/恢复全选会丢弃 `selectedColumns` 与 `excludedCells` |
| P2-6 | `lib/utils/ocr_digits.dart:20,44` | 多字母 token 无保护，实跑 `AB -> 48`（不影响合法通道，但可能把文本噪声变数值） |
| P2-7 | `lib/providers/calculation_provider.dart`（全文无 `channel`） | E.co 三通道「不可混算」仅在解析层分类，计算层未校验空白行/含菌行通道一致性，可跨通道混算 |
| P2-8 | `python/ocr_engine.py:158,1076,1162,1182-1187`；`lib/services/image_crop_service.dart:237-240` | 2000 硬阈值不连续 + 高瘦图漏网；无条件全图解码；仅 rapid 分支生效；「缩放 + 总铜族失去补识别」组合未实测 |
| P2-9 | `python/ocr_engine.py:1170` | `engine(ocr_input)` 抛异常时直接 `_emit error`，未回退 `engine(image_path)` 重试 |

### 通过项（不退回）

静态基线 3 条命令、负向 grep 全 0、条件缩放坐标一致性守卫、协议/降级三层安全网、Dart 侧格式兼容、`pinchScale` 全部边界、`fixOcrDigits` 通道字母保护 A、`resolvedExecutable` 改名 C、CMake OPTIONAL D、首页溢出 E、全选/反选闭环 F、四角裁剪 G、时间列 H、首轮 6 条业务规则 1/2/3/4/6。

---

## 6. 智能路由判定

- **源码存在 Bug（P1×3 + P2×9）** → **Send To: Engineer**
- 测试代码本身无错误断言，但 `widget_test.dart:101-111` 属「复刻被测逻辑」型弱断言，建议 QA 后续补强（不阻塞本轮）。
- 最终判定：**QA_PASS: NO**；**路由 = Engineer**（需退回工程师修复 P1-1 / P1-2 / P1-3，并对 P2 项逐项确认）。
- 本报告为 **Round 1 静态审查 + 独立实跑**；按 2 轮上限，工程师修复后我做一次 Round 2 回归（重点复跑 §3.1 的 `_merge` 探针与 §2-F 的小数点攻击探针），仍失败则转为 Known Issues 收口。

---

*附：本次临时探针 `qa_dart_probe.dart` / `qa_decimal_probe.py` 及日志均已删除，未修改任何产品代码（lib/、python/、windows/），未提交 git。*
