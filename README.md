# 水质检测仪助手 (Water Quality Detector Assistant)

面向现场水质检测人员的跨平台辅助工具。基于 Flutter 构建，同时适配 **Android 手机端**与 **Windows 桌面端**，蓝白配色（主色 `#1976D2` / `#E3F2FD`）。

## 简介

把检测仪屏幕上读到的数据、以及「仪器是否合格」这件事，从纸笔/Excel 手工计算，迁移到一个可复用的软件流程里：

- **图片转 Excel**：拍照或相册选取检测仪屏幕截图，OCR 识别表格 → 编辑 → 导出 Excel。
- **大肠杆菌 / 吸光度计算**：吸光度 `= ln(空白/检测) × 10000`，空白<检测时反向取对数；拟合 `y = aX + b`（界面展示为 B/A），输出 A、B、R²。
- **设备间文件传输**：同一局域网内 Android 与 Windows 互发 Excel/图片文件，基于 HttpServer + UDP 广播发现 + 扫码配对。
- **国标仪器验证（总磷 HJ 103—2026）**：工作空间管理、数据导入、按浓度自动分段、逐步计算与判定、Excel 导出。

## 功能特性

### 1. 图片转 Excel（OCR）
- Android：Google ML Kit 端侧离线中文识别（模型随 APK 打包，无需联网）。
- Windows：本地 Python（PaddleOCR）子进程离线识别；预留可选云端适配器（HTTP）。
- 识别结果可编辑、去重（按「采样日期|采样时间|通道」）、导出 Excel。

### 2. 大肠杆菌 / 吸光度计算
- 吸光度公式：`A = ln(空白/检测) × 10000`；空白 < 检测时取 `ln(检测/空白)`。
- 仅用「空白」「检测」两列；空值 / 非数值 / ≤0 返回 null 并提示。
- 线性拟合 `y = aX + b`，斜率 a 展示为 **B**、截距 b 展示为 **A**，输出 A、B、R²（两点时 R²=1）。

### 3. 设备间文件传输
- 协议：HttpServer（端口 54000 优先，占用时动态回退）+ UDP(54001) 广播发现。
- 桌面端展示二维码（内容 `WQA|1.0|{ip}:{port}|{token}`），手机端 mobile_scanner 扫码配对；配对后任一端可双向发文件。

### 4. 国标仪器验证（总磷 HJ 103—2026）
- **工作空间**：新建（合同编号可为空，检测项目下拉 COD / 总氮 / 总磷 / 氨氮）；支持草稿空间，未保存退出时提示是否保存。
- **数据导入**：复用「图片转 Excel」识别界面并回传数据集；或导入其他工作空间 / Excel 文件。
- **计算设置**：先选检测项目 → 选数据集或指定行 → 引擎按浓度自动分组（基本量程 0.02–4 mg/L 分 10%/20%/50%/80% 四档；扩展量程 4–50 mg/L）→ 用户勾选每段是否「参与计算」。数据不足时**默认不勾选全部**，提供全选/反选切换。
- **跨验证项行复用**：同一批数据同时服务多个验证项（如示值误差与重复性共用 0.8 mg/L 数据）时，以强调色 + 文案提示「该数据集已有 XX 选定」，不阻断、不禁用。
- **计算过程**：逐步展示公式与文字说明（判定用原始未舍入值，展示时按项舍入）。
- **判定严格性（合规底线）**：
  - 数据量不足 / 仅验证部分浓度档 / 仅计算部分验证项 → **记录数值但结论为「无法判定」**，绝不出具「合格」结论。
  - 漂移项等要求多条测量的项，条数不够按标准判「无法判定」。
- **导出 Excel**：多 Sheet，含「计算用数据集」「逐步计算过程」「判定用原始值（未舍入）」「结论说明」。

> 当前完整实现：**总磷（HJ 103—2026）**。COD / 总氮 / 氨氮 已在框架内占位，选择后提示「暂未实现」。

## 技术栈

| 领域 | 选型 |
|---|---|
| 框架 | Flutter 3.47.5 / Dart 3.13 |
| 状态管理 | provider |
| 表格读写 | excel |
| 图表 | fl_chart |
| 扫码 / 二维码 | mobile_scanner + qr_flutter |
| 相机 / 相册 / 文件 | camera / image_picker / file_picker |
| 端侧 OCR（Android） | google_mlkit_text_recognition |
| 网络 | http |
| 本地存储 | shared_preferences / path_provider / uuid |

## 目录结构

```
lib/
  core/        平台判断与常量
  models/      数据模型（standard / workspace / gb_verify ...）
  services/    业务服务（OCR、国标计算引擎 gb_calculator、导出、存储、传输）
  providers/   Provider 状态
  pages/       页面（首页 / 图片转Excel / 验证 / ...）
    verification/  国标验证（工作空间、计算设置、计算结果）
  utils/       解析与工具
  widgets/     复用组件
python/        Windows 桌面端 OCR 引擎（PaddleOCR）源码与打包脚本
windows/ocr_engine/  桌面 OCR 可分发产物（约 237MB，已打包，无需重建即可运行）
docs/          需求(PRD)、架构、国标计算规范、QA 报告、类图/时序图(mermaid)
```

## 环境要求

- Flutter SDK 3.47.x、Dart 3.13.x
- Android SDK（手机端运行/构建）
- Windows 桌面开发环境（桌面端运行/构建）
- 桌面离线 OCR：直接使用 `windows/ocr_engine/`（已含），无需安装 Python；如需重建，见 `python/build_engine*.bat`（需 Python 3.13 + PaddleOCR）

## 运行

```bash
flutter pub get
flutter run -d windows     # 桌面端
flutter run -d <android>   # 手机端
```

## 桌面 OCR 引擎说明

`windows/ocr_engine/` 为 Windows 桌面端离线识别的可分发产物（约 237MB），由 `python/ocr_engine.py` 经 PyInstaller 打包而成。仓库直接包含该产物，克隆后即可 `flutter run -d windows` 使用桌面 OCR，无需本地重建。

## 国标验证说明

- 权威计算依据：`docs/GB_HJ103_TP_SPEC.md`（由标准原文逐条整理，含浓度分类、13 项判定公式与限值、分段部分验证规则）。
- 实现与文档冲突时，以 `docs/GB_HJ103_TP_SPEC.md` 为准；与标准原文冲突时，以标准原文为准。
- 计算引擎为纯函数，返回可审计的逐步 `CalcStep`；判定在「数据充分」「覆盖完整」「各项全算」三层闸门后才会出具「合格」。

## 文档索引（docs/）

| 文件 | 内容 |
|---|---|
| `PRD.md` / `PRD_tp_v2.md` | 产品需求（通用 / 国标验证重做版） |
| `ARCHITECTURE.md` / `ARCHITECTURE_tp_v2.md` | 架构与任务分解（通用 / 国标验证重做版） |
| `GB_HJ103_TP_SPEC.md` | 总磷国标计算规范（权威依据） |
| `QA_REPORT.md` / `QA_REPORT_tp_v2.md` | 代码级质量审查记录 |
| `*.mermaid` | 类图 / 时序图 |

## 验证与测试

- 计算引擎有多组纯函数回归用例（位于 `.tmp_ocr_test/`，本地用 `dart` 运行；因本机 Windows 管道限制无法 `flutter test`，改用其做合规回归）。
- 静态分析与独立合规性审查记录见 `docs/QA_REPORT*.md`。

## 许可证

暂未指定。如需开源，请补充 `LICENSE` 文件。
