import 'package:flutter_test/flutter_test.dart';

import 'package:water_quality_detector_assistant/models/crop_quad.dart';
import 'package:water_quality_detector_assistant/models/crop_rect.dart';
import 'package:water_quality_detector_assistant/models/instrument_type.dart';
import 'package:water_quality_detector_assistant/models/ocr_parse_result.dart';
import 'package:water_quality_detector_assistant/models/table_selection.dart';
import 'package:water_quality_detector_assistant/models/water_quality_row.dart';
import 'package:water_quality_detector_assistant/models/workspace.dart';
import 'package:water_quality_detector_assistant/services/image_crop_service.dart';
import 'package:water_quality_detector_assistant/services/workspace_store.dart';
import 'package:water_quality_detector_assistant/utils/ocr_digits.dart';
import 'package:water_quality_detector_assistant/utils/ocr_layout.dart';
import 'package:water_quality_detector_assistant/utils/ocr_parser.dart';
import 'package:water_quality_detector_assistant/utils/workspace_utils.dart';

void main() {
  group('工作空间命名', () {
    test('按 项目名称-合同编号-负责人-检测项目-备注 拼接', () {
      expect(
        Workspace.buildName('水质监测', 'HT-2026', '张三', '总磷', '复核'),
        '水质监测-HT-2026-张三-总磷-复核',
      );
    });

    test('选填字段为空时省略该段', () {
      expect(
        Workspace.buildName('水质监测', 'HT-2026', '', '', ''),
        '水质监测-HT-2026',
      );
      expect(Workspace.buildName('项目', 'C1', '', '总磷', ''), '项目-C1-总磷');
    });

    test('文件夹名清洗非法字符', () {
      expect(sanitizeFolderName('  项目/名称:测试?  '), '项目 名称 测试');
      expect(sanitizeFolderName('...'), '');
    });

    test('Workspace.folderName 取拼接名', () {
      final Workspace ws = Workspace(
        name: 'fallback',
        parameter: 'tp',
        projectName: '项目A',
        contractNo: 'C001',
      );
      expect(ws.displayName, '项目A-C001');
      expect(ws.folderName, '项目A-C001');
    });
  });

  group('检测项目推断国标参数', () {
    test('氨氮 / 总氮 / 总磷 / 默认', () {
      expect(guessStandardParameter('氨氮在线监测'), 'nh3n');
      expect(guessStandardParameter('总氮'), 'tn');
      expect(guessStandardParameter('总磷 HJ 103'), 'tp');
      expect(guessStandardParameter('其他'), 'tp');
    });
  });

  group('四角裁剪框', () {
    test('clamp 约束到 0..1 且交换反向边', () {
      final CropRect r = const CropRect(
        left: 0.8,
        top: -0.2,
        right: 0.2,
        bottom: 1.4,
      ).clamp();
      expect(r.left, 0.2);
      expect(r.right, 0.8);
      expect(r.top, 0.0);
      expect(r.bottom, 1.0);
      expect(r.isValid, isTrue);
    });

    test('整图裁剪框有效', () {
      expect(CropRect.full.isValid, isTrue);
    });
  });

  group('CropQuad 四点独立', () {
    const CropQuad q = CropQuad(
      tl: Offset(0.10, 0.10),
      tr: Offset(0.90, 0.12),
      br: Offset(0.88, 0.92),
      bl: Offset(0.08, 0.90),
    );

    test('clamp 只钳制越界点，其余三点坐标保持不变', () {
      final CropQuad c = const CropQuad(
        tl: Offset(-0.3, 1.4),
        tr: Offset(0.90, 0.12),
        br: Offset(0.88, 0.92),
        bl: Offset(0.08, 0.90),
      ).clamp();
      expect(c.tl, const Offset(0.0, 1.0));
      expect(c.tr, const Offset(0.90, 0.12));
      expect(c.br, const Offset(0.88, 0.92));
      expect(c.bl, const Offset(0.08, 0.90));
    });

    test('拖动 tl 时 tr/br/bl 三个 Offset 原样保持不变', () {
      // 复刻 CroppableImage._onCornerDrag(corner=0) 的构造方式：
      // 只替换 tl，其余三点直接取旧 quad 的 Offset 原样带入。
      const Offset moved = Offset(0.22, 0.24);
      final CropQuad next = CropQuad(tl: moved, tr: q.tr, br: q.br, bl: q.bl);
      expect(next.tl, moved);
      expect(next.tr, q.tr);
      expect(next.br, q.br);
      expect(next.bl, q.bl);
      expect(next.isValid, isTrue);
    });

    test('isValid 用面积判定退化四边形', () {
      expect(CropQuad.full.isValid, isTrue);
      expect(CropQuad.full.area, closeTo(1.0, 1e-9));
      const CropQuad degenerate = CropQuad(
        tl: Offset(0, 0),
        tr: Offset(0, 0),
        br: Offset(0, 0),
        bl: Offset(0, 0),
      );
      expect(degenerate.isValid, isFalse);
    });

    test('toBoundingRect 取四点外接矩形', () {
      final r = q.toBoundingRect();
      expect(r.left, 0.08);
      expect(r.top, 0.10);
      expect(r.right, 0.90);
      expect(r.bottom, 0.92);
    });

    test('fromRect 按 tl/tr/br/bl 顺序展开', () {
      final CropQuad full = CropQuad.fromRect(CropRect.full);
      expect(full.tl, CropQuad.full.tl);
      expect(full.tr, CropQuad.full.tr);
      expect(full.br, CropQuad.full.br);
      expect(full.bl, CropQuad.full.bl);
    });
  });

  group('cropQuad 单应求解 / 降级判定', () {
    test('矩形四点得到线性映射系数', () {
      final List<double>? k = ImageCropService.solveHomography(<Offset>[
        const Offset(0.1, 0.1),
        const Offset(0.9, 0.1),
        const Offset(0.9, 0.9),
        const Offset(0.1, 0.9),
      ]);
      expect(k, isNotNull);
      expect(k!.length, 8);
      expect(k[0], closeTo(0.8, 1e-6)); // a
      expect(k[1], closeTo(0.0, 1e-6)); // b
      expect(k[2], closeTo(0.1, 1e-6)); // c
      expect(k[3], closeTo(0.0, 1e-6)); // d
      expect(k[4], closeTo(0.8, 1e-6)); // e
      expect(k[5], closeTo(0.1, 1e-6)); // f
      expect(k[6], closeTo(0.0, 1e-6)); // g
      expect(k[7], closeTo(0.0, 1e-6)); // h
    });

    test('退化四点（奇异矩阵）返回 null，触发外接矩形降级', () {
      final List<double>? k = ImageCropService.solveHomography(<Offset>[
        const Offset(0, 0),
        const Offset(0, 0),
        const Offset(0, 0),
        const Offset(0, 0),
      ]);
      expect(k, isNull);
      // 降级路径参数校验：非法 quad 的 isValid=false，cropQuad 会走
      // cropImage(toBoundingRect())，不抛异常。
      const CropQuad bad = CropQuad(
        tl: Offset(0, 0),
        tr: Offset(0, 0),
        br: Offset(0, 0),
        bl: Offset(0, 0),
      );
      expect(bad.isValid, isFalse);
      expect(bad.toBoundingRect().isValid, isFalse);
    });

    test('参数数量不符时返回 null（安全降级）', () {
      expect(
        ImageCropService.solveHomography(<Offset>[const Offset(0, 0)]),
        isNull,
      );
    });
  });

  group('OCR 表格行重排', () {
    test('按视觉行聚类、行内按 x 从左到右', () {
      final List<OcrLine> lines = <OcrLine>[
        const OcrLine(left: 200, top: 10, height: 20, text: '12205'),
        const OcrLine(left: 10, top: 10, height: 20, text: '2026-01-01'),
        const OcrLine(left: 100, top: 11, height: 18, text: '08:00'),
        const OcrLine(left: 10, top: 40, height: 20, text: '2026-01-02'),
        const OcrLine(left: 100, top: 41, height: 18, text: '09:00'),
      ];
      expect(layoutOcrLines(lines), '2026-01-01 08:00 12205\n2026-01-02 09:00');
    });

    test('空输入返回空串', () {
      expect(layoutOcrLines(const <OcrLine>[]), '');
    });

    test('纵向偏移大的行不会被合并', () {
      final List<OcrLine> lines = <OcrLine>[
        const OcrLine(left: 0, top: 0, height: 20, text: 'A'),
        const OcrLine(left: 0, top: 30, height: 20, text: 'B'),
      ];
      expect(layoutOcrLines(lines), 'A\nB');
    });
  });

  group('OCR 文本解析', () {
    test('相邻单元格粘连的日期时间可正常解析', () {
      final OcrParseResult result = parseOcrText(
        '2026-01-0108:00 12169 MPN/L 1.0 2.0',
        InstrumentType.mcgs,
      );
      expect(result.rows.length, 1);
      expect(result.rows.first.cells['采样日期'], '2026-01-01');
      expect(result.rows.first.cells['采样时间'], '08:00');
    });

    test('总铜时间列同时保留日期与时间', () {
      final OcrParseResult result = parseOcrText(
        '2026-11-03 18:00:00 28.2945 0.9329 N 1370.550 3570.500',
        InstrumentType.totalCopper,
      );
      expect(result.rows.length, 1);
      final String time = result.rows.first.cells['时间'] ?? '';
      expect(time.contains('2026-11-03'), isTrue);
      expect(time.contains('18:00:00'), isTrue);
    });
  });

  group('总铜列语义对齐（数据标识 N 缺失容错）', () {
    const String header = '时间 数据结果 吸光度 数据标识 当前值 空白值\n';

    test('4 个数值从右往左锚定，N 缺失时补齐并给出 warning', () {
      final OcrParseResult result = parseOcrText(
        '$header'
        '2026-11-03 18:00:00 25.2945 0.9329 1376.550 3570.500',
        InstrumentType.totalCopper,
      );
      expect(result.rows.length, 1);
      final row = result.rows.first;
      expect(row.cells['数据结果'], '25.2945');
      expect(row.cells['吸光度'], '0.9329');
      expect(row.cells['数据标识'], 'N');
      expect(row.cells['当前值'], '1376.550');
      expect(row.cells['空白值'], '3570.500');
      expect(result.warnings.any((String w) => w.contains('数据标识')), isTrue);
    });

    test('3 个数值时按吸光度特征分配，缺失列留空不塞错列', () {
      final OcrParseResult result = parseOcrText(
        '$header'
        '2026-11-03 14:00:00 1.4835 789.650 3566.000',
        InstrumentType.totalCopper,
      );
      expect(result.rows.length, 1);
      final row = result.rows.first;
      expect(row.cells['吸光度'], '1.4835');
      expect(row.cells['数据结果'], '');
      expect(row.cells['当前值'], '789.650');
      expect(row.cells['空白值'], '3566.000');
      expect(row.cells['数据标识'], 'N');
    });

    test('黏连 N 拆分为独立列，识别到 N 时不再提示推断补齐', () {
      final OcrParseResult result = parseOcrText(
        '$header'
        '2026-11-03 18:00:00 25.2945 0.9329N 1376.550 3570.500',
        InstrumentType.totalCopper,
      );
      expect(result.rows.length, 1);
      expect(result.rows.first.cells['数据标识'], 'N');
      expect(result.rows.first.cells['吸光度'], '0.9329');
      expect(result.warnings.any((String w) => w.contains('推断补齐')), isFalse);
    });

    test('左侧菜单词与脏数值写法不破坏列对齐', () {
      final OcrParseResult result = parseOcrText(
        '$header'
        '校准记录 2026-11-03 10:00:00 39. 9668 1.4624 808.550 3573.100\n'
        '2026-11-03 11:00:00 1-4867 828.100 3568.650',
        InstrumentType.totalCopper,
      );
      expect(result.rows.length, 2);
      expect(result.rows[0].cells['数据结果'], '39.9668');
      expect(result.rows[0].cells['吸光度'], '1.4624');
      expect(result.rows[1].cells['吸光度'], '1.4867');
      expect(result.rows[1].cells['空白值'], '3568.650');
    });
  });

  group('OCR 数字纠错', () {
    test('形似字符纠正为数字', () {
      expect(fixOcrDigits('l370.550'), '1370.550');
      expect(fixOcrDigits('O.9329'), '0.9329');
      expect(fixOcrDigits('1,370.550'), '1370.550');
    });

    test('日期 / 时间 / 通道标识受保护不被改写', () {
      expect(fixOcrDigits('2026-11-03'), '2026-11-03');
      expect(fixOcrDigits('18:00:00'), '18:00:00');
      expect(fixOcrDigits('A'), 'A');
      expect(fixOcrDigits('未检出'), '未检出');
    });
  });

  group('表格勾选 全选 / 反选', () {
    test('noneSelected 时 apply 返回 0 行，再次全选恢复全部行', () {
      final List<WaterQualityRow> rows = <WaterQualityRow>[
        WaterQualityRow.fromCells(
          instrument: InstrumentType.mcgs,
          cells: <String, String>{
            '采样日期': '2026-11-03',
            '采样时间': '18:00',
            '总大肠杆菌': '10',
          },
        ),
        WaterQualityRow.fromCells(
          instrument: InstrumentType.mcgs,
          cells: <String, String>{
            '采样日期': '2026-11-03',
            '采样时间': '19:00',
            '总大肠杆菌': '20',
          },
        ),
      ];
      final List<String> headers = InstrumentType.mcgs.headers;
      final TableSelection all = TableSelection();
      expect(all.apply(rows, headers).length, 2);
      final TableSelection none = TableSelection(noneSelected: true);
      expect(none.apply(rows, headers).length, 0);
      expect(TableSelection().apply(rows, headers).length, 2);
    });
  });

  test('搜索字段包含全部 / 合同编号 / 项目名称', () {
    expect(SearchField.values.length, 3);
    expect(SearchField.values, contains(SearchField.contractNo));
    expect(SearchField.values, contains(SearchField.projectName));
  });
}
