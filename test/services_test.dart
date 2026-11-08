import 'package:flutter_test/flutter_test.dart';

import 'package:water_quality_detector_assistant/models/fit_result.dart';
import 'package:water_quality_detector_assistant/models/instrument_type.dart';
import 'package:water_quality_detector_assistant/models/ocr_parse_result.dart';
import 'package:water_quality_detector_assistant/models/peer_device.dart';
import 'package:water_quality_detector_assistant/models/water_quality_row.dart';
import 'package:water_quality_detector_assistant/services/dedup_service.dart';
import 'package:water_quality_detector_assistant/services/fit_service.dart';
import 'package:water_quality_detector_assistant/services/qr_service.dart';
import 'package:water_quality_detector_assistant/utils/number_utils.dart';
import 'package:water_quality_detector_assistant/utils/ocr_parser.dart';

void main() {
  group('FitService', () {
    final FitService fit = FitService();

    test('吸光度计算：空白 >= 检测', () {
      expect(fit.calcAbsorbance(100, 50), closeTo(6931.4718, 0.01));
    });

    test('吸光度计算：空白 < 检测时反向', () {
      expect(fit.calcAbsorbance(50, 100), closeTo(6931.4718, 0.01));
    });

    test('吸光度计算：空/非正值返回 null', () {
      expect(fit.calcAbsorbance(null, 50), isNull);
      expect(fit.calcAbsorbance(100, 0), isNull);
      expect(fit.calcAbsorbance(-1, 50), isNull);
    });

    test('线性拟合：两点得到精确直线', () {
      final FitResult r = fit.linearFit(<FitPoint>[
        FitPoint(0, 2),
        FitPoint(10, 12),
      ]);
      expect(r.slope, closeTo(1.0, 1e-9));
      expect(r.intercept, closeTo(2.0, 1e-9));
      expect(r.rSquared, closeTo(1.0, 1e-9));
    });

    test('线性拟合：空点退化', () {
      final FitResult r = fit.linearFit(<FitPoint>[]);
      expect(r.slope, 0);
      expect(r.intercept, 0);
      expect(r.rSquared, 0);
    });
  });

  group('DedupService', () {
    final DedupService dedup = DedupService();

    test('按去重键去重并保留首次出现', () {
      final List<WaterQualityRow> rows = <WaterQualityRow>[
        WaterQualityRow(
          id: '1',
          instrument: InstrumentType.mcgs,
          sampleDate: '2024-01-01',
          sampleTime: '10:00',
        ),
        WaterQualityRow(
          id: '2',
          instrument: InstrumentType.mcgs,
          sampleDate: '2024-01-01',
          sampleTime: '10:00',
        ),
        WaterQualityRow(
          id: '3',
          instrument: InstrumentType.mcgs,
          sampleDate: '2024-01-02',
          sampleTime: '10:00',
        ),
      ];
      final List<WaterQualityRow> result = dedup.dedup(rows);
      expect(result.length, 2);
      expect(result.first.id, '1');
    });

    test('无通道仪器用仪器简称作为键的一部分', () {
      final WaterQualityRow row = WaterQualityRow(
        id: '1',
        instrument: InstrumentType.mcgs,
        sampleDate: '2024-01-01',
        sampleTime: '10:00',
      );
      expect(row.dedupKey, '2024-01-01|10:00|MCGS');
    });
  });

  group('NumberUtils', () {
    test('数值解析', () {
      expect(NumberUtils.parseNumber('9000'), 9000);
      expect(NumberUtils.parseNumber('0.123'), closeTo(0.123, 1e-9));
      expect(NumberUtils.parseNumber('1,234.5'), closeTo(1234.5, 1e-9));
      expect(NumberUtils.parseNumber('１２３.４'), closeTo(123.4, 1e-9));
    });

    test('未检出/空返回 null', () {
      expect(NumberUtils.parseNumber('未检出'), isNull);
      expect(NumberUtils.parseNumber(''), isNull);
      expect(NumberUtils.parseNumber(null), isNull);
    });
  });

  group('QrService', () {
    final QrService qr = QrService();

    test('构造与解析二维码内容', () {
      final PeerDevice self = PeerDevice(
        name: 'pc',
        ip: '192.168.1.10',
        port: 54000,
        token: 'A1B2C3D4',
        platform: 'windows',
      );
      final String content = qr.buildQrContent(self);
      expect(content, 'WQA|1.0|192.168.1.10:54000|A1B2C3D4');

      final PeerDevice? parsed = qr.parseQrContent(content);
      expect(parsed, isNotNull);
      expect(parsed!.ip, '192.168.1.10');
      expect(parsed.port, 54000);
      expect(parsed.token, 'A1B2C3D4');
    });

    test('非法内容返回 null', () {
      expect(qr.parseQrContent('bad'), isNull);
      expect(qr.parseQrContent('WQA|2.0|1.2.3.4:54000|TOKEN'), isNull);
    });
  });

  group('OcrParser', () {
    test('MCGS 行解析', () {
      final OcrParseResult result = parseOcrText(
        '2024-01-01 10:00 9000 MPN/L 0.100 0.050',
        InstrumentType.mcgs,
      );
      expect(result.rows.length, 1);
      final WaterQualityRow row = result.rows.first;
      expect(row.sampleDate, '2024-01-01');
      expect(row.sampleTime, '10:00');
      expect(row.result, '9000');
      expect(row.unit, 'MPN/L');
      expect(row.blankRaw, '0.100');
      expect(row.detectionRaw, '0.050');
      expect(row.blank, closeTo(0.100, 1e-9));
    });

    test('E.co 行解析（含通道）', () {
      final OcrParseResult result = parseOcrText(
        '2024-01-01 10:00 大肠埃希氏菌B 未检出 0.100 0.050',
        InstrumentType.eco,
      );
      expect(result.rows.length, 1);
      final WaterQualityRow row = result.rows.first;
      expect(row.channel, '大肠埃希氏菌B');
      expect(row.result, '未检出');
      expect(row.detection, closeTo(0.050, 1e-9));
    });

    test('总铜行解析（自带吸光度）', () {
      final OcrParseResult result = parseOcrText(
        '10:00 0.05 0.123 有效 1.0 0.9',
        InstrumentType.totalCopper,
      );
      expect(result.rows.length, 1);
      final WaterQualityRow row = result.rows.first;
      expect(row.sampleTime, '10:00');
      expect(row.absorbance, closeTo(0.123, 1e-9));
    });
  });
}
