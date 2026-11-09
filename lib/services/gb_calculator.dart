import 'dart:math' as math;

import '../models/gb_verify.dart';
import '../models/standard.dart';

/// 国标验证计算引擎（HJ 103—2026 总磷）。
///
/// 设计要点：
/// 1. **纯函数**：不依赖 Flutter / 文件系统，可单测；
/// 2. **返回 [ItemReport]**，内部生成有序 [CalcStep]（公式 + 代入 + 结果 + 说明），
///    满足"每一步计算过程都要展示"的要求；
/// 3. 公式严格按标准原文实现，见 `docs/GB_HJ103_TP_SPEC.md`；
/// 4. 判定使用**未舍入**的计算值，展示时才舍入（避免边界误判）。
///
/// 调用方式：
/// ```dart
/// final List<GbSegment> segs = GbCalculator.autoBind(samples, specs);
/// final ItemReport r = GbCalculator.compute(
///   item: totalPhosphorusStandard.itemById('indication_error')!,
///   rangeKey: 'basic',
///   segments: segs,
/// );
/// ```
class GbCalculator {
  GbCalculator._();

  // ---------------------------------------------------------------- 常量

  /// 基本检测范围上限（mg/L）。
  static const double basicUpper = 4.0;

  /// 扩展检测范围上限（mg/L）。
  static const double extendedUpper = 50.0;

  /// 基本检测范围下限（mg/L），即定量下限试验浓度。
  static const double basicLower = 0.02;

  /// 实际样品比对浓度分界（mg/L）。
  static const double compareSplit = 0.4;

  /// 实际样品比对低浓度档的绝对限值（mg/L）。
  static const double compareAbsoluteLimit = 0.04;

  /// 浓度档位容差（相对值），用于自动归类与"浓度不符"提示。
  static const double levelTolerance = 0.05;

  /// 「这批数据是不是这个浓度」的判定容差（相对值）。
  ///
  /// 比 [levelTolerance] 宽松得多，因为两者用途不同：
  /// - [levelTolerance] 是**提示**阈值——偏离 5% 就提醒用户复核分类；
  /// - 这里是**归属性**判断——偏离超过 50% 说明这压根不是该浓度的数据
  ///   （例如把 0.8 mg/L 的行当成定量下限的 0.02 mg/L 溶液）。
  static const double concentrationMatchTolerance = 0.5;

  /// 量程上限值。
  static double upperLimitOf(String rangeKey) =>
      rangeKey == 'extended' ? extendedUpper : basicUpper;

  /// 量程中文标签。
  static String rangeLabel(String rangeKey) =>
      rangeKey == 'extended' ? '扩展检测范围（4～50 mg/L）' : '基本检测范围（0.02～4 mg/L）';

  /// 依据测定值判定所属量程：≥4 mg/L 归扩展，否则基本。
  static String rangeOf(double value) =>
      value >= basicUpper ? 'extended' : 'basic';

  /// 「上限值百分比」对应的浓度（mg/L）。
  static double levelOf(String rangeKey, int percent) =>
      upperLimitOf(rangeKey) * percent / 100.0;

  // ---------------------------------------------------------------- 分段规格

  /// 一个数据分段的要求（供计算设置页做自动归类与缺口提示）。
  static List<GbSegmentSpec> segmentSpecs(String itemId, String rangeKey) {
    final bool ext = rangeKey == 'extended';
    switch (itemId) {
      case 'indication_error':
        if (ext) {
          return <GbSegmentSpec>[
            GbSegmentSpec(
              key: 'lvl50',
              label: '上限值 50%（25 mg/L）',
              target: levelOf(rangeKey, 50),
              required: 6,
            ),
          ];
        }
        return <GbSegmentSpec>[
          for (final int p in <int>[10, 20, 50, 80])
            GbSegmentSpec(
              key: 'lvl$p',
              label: '上限值 $p%（${mgL(levelOf(rangeKey, p))}）',
              target: levelOf(rangeKey, p),
              required: 6,
            ),
        ];
      case 'loq':
        return <GbSegmentSpec>[
          GbSegmentSpec(
            key: 'loq',
            label: '范围下限 0.02 mg/L',
            target: basicLower,
            required: 7,
          ),
        ];
      case 'repeatability':
        if (ext) {
          return <GbSegmentSpec>[
            GbSegmentSpec(
              key: 'lvl50',
              label: '上限值 50%（25 mg/L）',
              target: levelOf(rangeKey, 50),
              required: 6,
            ),
          ];
        }
        return <GbSegmentSpec>[
          for (final int p in <int>[20, 80])
            GbSegmentSpec(
              key: 'lvl$p',
              label: '上限值 $p%（${mgL(levelOf(rangeKey, p))}）',
              target: levelOf(rangeKey, p),
              required: 6,
            ),
        ];
      case 'drift_low24h':
        return <GbSegmentSpec>[
          GbSegmentSpec(
            key: 'series',
            label: '约 0.1 mg/L，连续 24 h',
            target: 0.1,
            required: 24,
            unit: 'h',
          ),
        ];
      case 'drift_high24h':
        return <GbSegmentSpec>[
          GbSegmentSpec(
            key: 'series',
            label: ext
                ? '上限值 80%（40 mg/L），连续 24 h'
                : '上限值 80%（3.2 mg/L），连续 24 h',
            target: levelOf(rangeKey, 80),
            required: 24,
            unit: 'h',
          ),
        ];
      case 'memory_80to20':
        // 标准试验顺序：连续 3 次 80%（不考核）→ 20% 连续 7 次 → 80% 连续 7 次。
        // 本项判定 20% 段（80%→20% 方向的记忆残留）。
        return <GbSegmentSpec>[
          GbSegmentSpec(
            key: 'pre',
            label: '前置 80%（3.2 mg/L）3 次，不考核',
            target: levelOf('basic', 80),
            required: 3,
            discard: true,
          ),
          GbSegmentSpec(
            key: 'low',
            label: '20%（0.8 mg/L）连续 7 次',
            target: levelOf('basic', 20),
            required: 7,
          ),
        ];
      case 'memory_20to80':
        // 同上试验，本项判定 80% 段（20%→80% 方向的记忆残留）。
        return <GbSegmentSpec>[
          GbSegmentSpec(
            key: 'pre',
            label: '前置 80%（3.2 mg/L）3 次，不考核',
            target: levelOf('basic', 80),
            required: 3,
            discard: true,
          ),
          GbSegmentSpec(
            key: 'low',
            label: '20%（0.8 mg/L）连续 7 次（过渡段）',
            target: levelOf('basic', 20),
            required: 7,
          ),
          GbSegmentSpec(
            key: 'high',
            label: '80%（3.2 mg/L）连续 7 次',
            target: levelOf('basic', 80),
            required: 7,
          ),
        ];
      case 'voltage':
        return <GbSegmentSpec>[
          for (final String v in <String>['220', '242', '198'])
            GbSegmentSpec(
              key: 'v$v',
              label: '$v V 连续 3 次',
              target: levelOf('basic', 80),
              required: 3,
            ),
        ];
      case 'turbidity':
        return <GbSegmentSpec>[
          for (final String t in <String>['0', '100', '300'])
            GbSegmentSpec(
              key: 't$t',
              label: t == '0' ? '无浊度 3 次' : '$t NTU 3 次',
              target: levelOf('basic', 10),
              required: 3,
            ),
        ];
      case 'temperature':
        const Map<String, String> tempSeq = <String, String>{
          '20a': '20 ℃（第 1 段）连续 3 次',
          '5': '5 ℃ 连续 3 次',
          '20b': '20 ℃（第 2 段）连续 3 次',
          '40': '40 ℃ 连续 3 次',
          '20c': '20 ℃（第 3 段）连续 3 次',
        };
        return <GbSegmentSpec>[
          for (final String k in tempSeq.keys)
            GbSegmentSpec(
              key: 't$k',
              label: tempSeq[k]!,
              target: levelOf('basic', 80),
              required: 3,
            ),
        ];
      case 'sample_compare':
        return <GbSegmentSpec>[
          GbSegmentSpec(
            key: 'sample',
            label: '同一样品仪器连续测量不少于 10 次',
            target: null,
            required: 10,
          ),
        ];
      case 'conformity':
        return <GbSegmentSpec>[
          for (int i = 1; i <= 3; i++)
            GbSegmentSpec(
              key: 'inst$i',
              label: '第 $i 台仪器，168 组',
              target: null,
              required: 168,
            ),
        ];
      default:
        return const <GbSegmentSpec>[];
    }
  }

  /// 自动把选中的数据按"最接近的目标浓度"归入各分段。
  ///
  /// 用于浓度档位类项目（示值误差、重复性）；条件类项目（电压/浊度/温度）
  /// 由用户在 UI 上手动绑定，不走此函数。
  static List<GbSegment> autoBindByLevel(
    List<GbSample> samples,
    List<GbSegmentSpec> specs,
  ) {
    final Map<String, List<GbSample>> buckets = <String, List<GbSample>>{
      for (final GbSegmentSpec s in specs) s.key: <GbSample>[],
    };
    final List<GbSegmentSpec> withTarget = specs
        .where((GbSegmentSpec s) => s.target != null)
        .toList();
    if (withTarget.isEmpty) {
      return <GbSegment>[
        for (final GbSegmentSpec s in specs)
          GbSegment(
            key: s.key,
            label: s.label,
            target: s.target,
            samples: <GbSample>[],
          ),
      ];
    }
    for (final GbSample smp in samples) {
      GbSegmentSpec? best;
      double bestDiff = double.infinity;
      for (final GbSegmentSpec s in withTarget) {
        final double diff = (smp.value - s.target!).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          best = s;
        }
      }
      if (best != null) buckets[best.key]!.add(smp);
    }
    return <GbSegment>[
      for (final GbSegmentSpec s in specs)
        GbSegment(
          key: s.key,
          label: s.label,
          target: s.target,
          samples: buckets[s.key] ?? <GbSample>[],
        ),
    ];
  }

  /// 顺序切分：把 [samples] 按各分段需要的条数依次分配（条件类项目默认策略）。
  ///
  /// **最后一段收全部剩余行**，不能只收到 `required` 条。原因：多段项目若严格按
  /// `required` 截断，选中行数一旦超过 `sum(required)`，多出的行就既不进任何段、
  /// 也不产生任何提示——用户以为全用上了，实际被静默丢弃。
  /// 收进最后一段后 [checkSegments] 才能提示「多出 N 条，计算仅使用前 N 条」；
  /// 各计算函数内部一律 `take(required)`，多出的行不会影响数值。
  static List<GbSegment> autoBindSequential(
    List<GbSample> samples,
    List<GbSegmentSpec> specs,
  ) {
    final List<GbSegment> out = <GbSegment>[];
    int cursor = 0;
    for (int i = 0; i < specs.length; i++) {
      final GbSegmentSpec s = specs[i];
      final bool last = i == specs.length - 1;
      final int take = last
          ? math.max(0, samples.length - cursor)
          : math.min(s.required, math.max(0, samples.length - cursor));
      final int end = math.min(samples.length, cursor + take);
      out.add(
        GbSegment(
          key: s.key,
          label: s.label,
          target: s.target,
          samples: samples.sublist(cursor, end),
        ),
      );
      cursor = end;
    }
    return out;
  }

  /// 记忆效应专用切分：先按浓度分桶，再把高浓度桶里「多出来的前几条」识别为
  /// 标准规定的「前置 3 次 80%（不考核）」。
  ///
  /// 标准试验顺序固定为 `3×80%(不考核) → 7×20% → 7×80%`，因此高浓度桶按
  /// 时间排序后，**末尾 7 条**才是参与判定的 80% 段，前面多出的才是前置段。
  /// 这样即使用户只提供 14 条（没有前置段）也能正确绑定。
  static List<GbSegment> autoBindMemory(
    List<GbSample> samples,
    List<GbSegmentSpec> specs,
  ) {
    final List<GbSample> ordered = List<GbSample>.of(samples)
      ..sort((GbSample a, GbSample b) => a.index.compareTo(b.index));

    double? lowTarget;
    double? highTarget;
    int highRequired = 7;
    for (final GbSegmentSpec s in specs) {
      if (s.key == 'low' && s.target != null) lowTarget = s.target;
      if ((s.key == 'high' || s.key == 'pre') && s.target != null) {
        highTarget = s.target;
      }
      if (s.key == 'high') highRequired = s.required;
    }
    lowTarget ??= levelOf('basic', 20);
    highTarget ??= levelOf('basic', 80);

    final List<GbSample> lowBucket = <GbSample>[];
    final List<GbSample> highBucket = <GbSample>[];
    for (final GbSample smp in ordered) {
      final double dLow = (smp.value - lowTarget).abs();
      final double dHigh = (smp.value - highTarget).abs();
      if (dHigh <= dLow) {
        highBucket.add(smp);
      } else {
        lowBucket.add(smp);
      }
    }

    List<GbSample> pre;
    List<GbSample> high;
    if (highBucket.length > highRequired + 1) {
      // 高浓度桶明显超过 7 条 → 多出来的前几条就是「前置 3 次 80%」。
      final int extra = highBucket.length - highRequired;
      pre = highBucket.sublist(0, extra);
      high = highBucket.sublist(extra);
    } else if (highBucket.length <= 4) {
      // 只有 3（或更少）条高浓度数据 → 用户只给了前置段，没有 80% 判定段。
      // 若不这样处理，这 3 条会落到一个 specs 里不存在的 `high` 段而被静默丢弃。
      pre = highBucket;
      high = const <GbSample>[];
    } else {
      // 7 条左右 → 没有前置段，全是参与判定的 80% 段。
      pre = const <GbSample>[];
      high = highBucket;
    }

    final Map<String, List<GbSample>> byKey = <String, List<GbSample>>{
      'pre': pre,
      'low': lowBucket,
      'high': high,
    };
    return <GbSegment>[
      for (final GbSegmentSpec s in specs)
        GbSegment(
          key: s.key,
          label: s.label,
          target: s.target,
          samples: byKey[s.key] ?? const <GbSample>[],
        ),
    ];
  }

  /// 统一绑定入口：按验证项自动选择切分策略。
  ///
  /// UI 只需要调这一个方法，不要再自己判断该用哪个策略。
  static List<GbSegment> autoBind(
    String itemId,
    List<GbSample> samples,
    List<GbSegmentSpec> specs,
  ) {
    if (specs.isEmpty) return const <GbSegment>[];
    switch (itemId) {
      case 'memory_80to20':
      case 'memory_20to80':
        return autoBindMemory(samples, specs);
      case 'indication_error':
      case 'repeatability':
      case 'loq':
        return autoBindByLevel(samples, specs);
      // 24 h 漂移标准要求「每小时 1 次、连续 24 h」，按采样时间绑定最贴近标准；
      // 时间不足或缺失严重时 [autoBindByHour] 内部回退顺序切分。
      case 'drift_low24h':
      case 'drift_high24h':
        return autoBindByHour(samples, specs);
      default:
        return autoBindSequential(samples, specs);
    }
  }

  /// 需要「按浓度档位互斥分配」的验证项。
  ///
  /// 这三项的每一档都要连续测 6（定量下限 7）次，同一条数据行只能服务其中一项
  /// 的一档，否则「示值误差 20% 档」与「重复性 20% 档」会抢同一批行，
  /// 用户以为两档都测了、其实是同一组数据被算了两次。
  static const Set<String> _levelAllocatedItemIds = <String>{
    'indication_error',
    'repeatability',
    'loq',
  };

  /// 为多个验证项一次性分配默认数据（互斥分配）。
  ///
  /// 场景：用户选中一批行、同时勾选「示值误差 + 重复性」，点开始计算时
  /// 需要给每一项都预填好分段。若各自独立按浓度分桶，同一批 0.8 mg/L 的 6 条行
  /// 会同时被两项占用（重复使用，结果虚高）。
  ///
  /// 分配规则：
  /// 1. 汇总所有档位类项目（[itemIds] 中的示值误差 / 重复性 / 定量下限）的目标浓度，
  ///    作为互斥分桶中心；每条数据行只归入**最接近**的那个浓度桶；
  /// 2. 桶内按 [GbSample.index] 升序排列，按 [itemIds] 顺序逐个项目、
  ///    每个项目按 [segmentSpecs] 顺序切出该档 `required` 条（桶内游标前进）；
  /// 3. 桶里剩余条数不够时该项目该档得空表（不跨桶借数据、不重复使用同一行）；
  /// 4. 非档位类项目（条件类/单序列类，如电压、温度、漂移、样品比对）
  ///    不受互斥约束，直接拿到全部 [samples]。
  ///
  /// 返回 Map 的 key 覆盖 [itemIds] 全部元素（顺序与入参一致）。
  static Map<String, List<GbSample>> allocateByLevel({
    required List<String> itemIds,
    required String rangeKey,
    required List<GbSample> samples,
  }) {
    final Map<String, List<GbSample>> out = <String, List<GbSample>>{};
    if (itemIds.isEmpty) return out;

    // 1) 收集档位类项目的全部目标浓度（去重）。
    final List<double> targets = <double>[];
    for (final String id in itemIds) {
      if (!_levelAllocatedItemIds.contains(id)) continue;
      for (final GbSegmentSpec spec in segmentSpecs(id, rangeKey)) {
        if (spec.discard) continue;
        final double? t = spec.target;
        if (t == null || t <= 0) continue;
        if (!targets.any((double v) => (v - t).abs() < 1e-9)) targets.add(t);
      }
    }

    // 没有任何浓度档位（例如只勾了电压/维护周期）：全部项目拿全部行。
    if (targets.isEmpty) {
      for (final String id in itemIds) {
        out[id] = List<GbSample>.of(samples);
      }
      return out;
    }

    final List<GbSample> ordered = List<GbSample>.of(samples)
      ..sort((GbSample a, GbSample b) => a.index.compareTo(b.index));

    // 2) 按最接近的目标浓度分桶（互斥：一行只进一个桶）。
    final Map<double, List<GbSample>> buckets = <double, List<GbSample>>{
      for (final double t in targets) t: <GbSample>[],
    };
    for (final GbSample smp in ordered) {
      double best = targets.first;
      double bestDiff = (smp.value - best).abs();
      for (final double t in targets) {
        final double diff = (smp.value - t).abs();
        if (diff < bestDiff) {
          bestDiff = diff;
          best = t;
        }
      }
      buckets[best]!.add(smp);
    }

    // 3) 逐项按规格顺序切桶，桶内游标前进（同一行不会被两个项目重复使用）。
    final Map<double, int> cursor = <double, int>{
      for (final double t in targets) t: 0,
    };
    for (final String id in itemIds) {
      if (!_levelAllocatedItemIds.contains(id)) {
        out[id] = List<GbSample>.of(ordered);
        continue;
      }
      final List<GbSample> picked = <GbSample>[];
      for (final GbSegmentSpec spec in segmentSpecs(id, rangeKey)) {
        if (spec.discard) continue;
        final double? t = spec.target;
        if (t == null || t <= 0) continue;
        // 规格目标浓度 → 对应的分桶中心（两者通常完全相同，这里按最近匹配兜底）。
        double key = targets.first;
        double bestDiff = (key - t).abs();
        for (final double cand in targets) {
          final double diff = (cand - t).abs();
          if (diff < bestDiff) {
            bestDiff = diff;
            key = cand;
          }
        }
        final List<GbSample> bucket = buckets[key] ?? <GbSample>[];
        final int start = cursor[key] ?? 0;
        if (start >= bucket.length) {
          cursor[key] = bucket.length;
          continue;
        }
        final int end = math.min(bucket.length, start + spec.required);
        picked.addAll(bucket.sublist(start, end));
        cursor[key] = end;
      }
      out[id] = picked;
    }
    return out;
  }

  /// 按采样时间绑定「连续 24 h」序列（24 h 漂移类项目的默认策略）。
  ///
  /// 标准要求「约 0.1 mg/L 溶液，每小时测定 1 次，连续 24 h」。用户按月导出的
  /// 数据集里同一小时可能有多条记录，若直接顺序切分，取到的前 24 条可能只覆盖
  /// 十几个小时，算出来的「漂移」其实反映的是分钟级波动。
  ///
  /// 规则：
  /// 1. 按 [GbSample.time] 升序（无时间的行排最后，同时间按 index 升序）；
  /// 2. 取**连续 24 个不同小时**、每小时**第一条**作为参与计算的 24 条；
  ///    多出来的行追加在同一分段末尾（[checkSegments] 会提示「多出 N 条」，
  ///    各计算函数内部一律 `take(required)`，不影响数值，也不会静默丢行）；
  /// 3. 可用小时数不足 24，或时间缺失严重（超过 20% 的行没有时间）时，
  ///    回退 [autoBindSequential]，行为与本函数引入前一致。
  ///
  /// 仅支持单分段序列（24 h 漂移只有一个 `series` 段）；多分段项目一律回退顺序切分。
  static List<GbSegment> autoBindByHour(
    List<GbSample> samples,
    List<GbSegmentSpec> specs,
  ) {
    if (specs.isEmpty) return const <GbSegment>[];
    if (specs.length != 1) return autoBindSequential(samples, specs);
    final GbSegmentSpec spec = specs.first;
    final int required = spec.required;
    if (samples.isEmpty || required <= 0) {
      return autoBindSequential(samples, specs);
    }

    final List<GbSample> ordered = List<GbSample>.of(samples)
      ..sort((GbSample a, GbSample b) {
        final DateTime? ta = a.time;
        final DateTime? tb = b.time;
        if (ta == null && tb == null) return a.index.compareTo(b.index);
        if (ta == null) return 1;
        if (tb == null) return -1;
        final int byTime = ta.compareTo(tb);
        return byTime != 0 ? byTime : a.index.compareTo(b.index);
      });

    int missing = 0;
    final List<GbSample> picked = <GbSample>[];
    final List<GbSample> rest = <GbSample>[];
    final Set<String> seenHours = <String>{};
    for (final GbSample smp in ordered) {
      final DateTime? t = smp.time;
      if (t == null) {
        missing++;
        rest.add(smp);
        continue;
      }
      final String hourKey = '${t.year}-${t.month}-${t.day}-${t.hour}';
      if (seenHours.length < required && !seenHours.contains(hourKey)) {
        seenHours.add(hourKey);
        picked.add(smp);
      } else {
        rest.add(smp);
      }
    }

    final bool tooFewHours = picked.length < required;
    // 时间缺失严重：超过 20% 的行没有时间戳，按小时绑定不可靠。
    final bool timeMissingSevere = missing * 5 > ordered.length;
    if (tooFewHours || timeMissingSevere) {
      return autoBindSequential(samples, specs);
    }

    return <GbSegment>[
      GbSegment(
        key: spec.key,
        label: spec.label,
        target: spec.target,
        samples: <GbSample>[...picked, ...rest],
      ),
    ];
  }

  // ---------------------------------------------------------------- 数据量校验

  /// 校验分段数据量，返回面向用户的中文提示；正常时返回空串。
  static String checkSegments(
    String itemId,
    String rangeKey,
    List<GbSegment> segments,
  ) {
    final List<GbSegmentSpec> specs = segmentSpecs(itemId, rangeKey);
    if (specs.isEmpty) return '';
    final List<String> problems = <String>[];
    for (int i = 0; i < specs.length; i++) {
      final GbSegmentSpec spec = specs[i];
      final GbSegment? seg = i < segments.length ? segments[i] : null;
      // 用户明确不参与计算的分段：既不提示不足、也不提示过多。
      if (seg != null && !seg.enabled) continue;
      // 前置「不考核」段不参与数据量校验与门禁；但条数超出时仍要告知用户
      // 「多出的行被忽略了」，否则用户会以为自己录入的全都被用上了。
      if (spec.discard) {
        final int dn = seg?.samples.length ?? 0;
        if (dn > spec.required) {
          problems.add('${spec.label}：本段不参与判定，已忽略多出的 ${dn - spec.required} 条');
        }
        continue;
      }
      final int n = seg?.samples.length ?? 0;
      if (n < spec.required) {
        problems.add(
          '${spec.label}：需要 ${spec.required} 条，当前 $n 条'
          '（不足，缺少 ${spec.required - n} 条）',
        );
        continue;
      }
      if (n > spec.required) {
        problems.add(
          '${spec.label}：需要 ${spec.required} 条，当前 $n 条'
          '（多出 ${n - spec.required} 条，计算仅使用前 ${spec.required} 条）',
        );
      }
      // 浓度档位符合性：该段实测均值与目标浓度偏差过大时提示用户复核分类。
      final double? target = spec.target;
      if (target != null && target > 0 && spec.unit != 'h' && seg != null) {
        final List<double> xs = seg.samples
            .take(spec.required)
            .map((GbSample s) => s.value)
            .toList();
        final double mean = _mean(xs);
        if (mean.isFinite && mean > 0) {
          final double dev = (mean - target) / target * 100;
          if (dev.abs() > levelTolerance * 100) {
            problems.add(
              '${spec.label}：实测均值 ${_fmt(mean, 3)}，与目标浓度 '
              '${_fmt(target, 3)} 偏差 ${_fmt(dev, 1)}%'
              '（超出 ±${_fmt(levelTolerance * 100, 0)}%，请确认该段浓度是否正确）',
            );
          }
        }
      }
    }
    return problems.join('；');
  }

  /// 数据量是否达到标准的判定要求。
  ///
  /// 只校验**启用中**且非 discard 的分段；任一启用分段条数不足
  /// [GbSegmentSpec.required] 时返回 false，此时 [compute] 会把结论强制置为
  /// 「无法判定」——**不得**在条数不足时出具合格/不合格结论。
  ///
  /// 若用户把所有分段都取消启用（没有任何数据参与），也返回 false。
  static bool dataSufficient(
    String itemId,
    String rangeKey,
    List<GbSegment> segments,
  ) {
    final List<GbSegmentSpec> specs = segmentSpecs(itemId, rangeKey);
    if (specs.isEmpty) return true;
    bool anyEnabled = false;
    for (int i = 0; i < specs.length; i++) {
      final GbSegmentSpec spec = specs[i];
      if (spec.discard) continue;
      final GbSegment? seg = i < segments.length ? segments[i] : null;
      if (seg != null && !seg.enabled) continue;
      anyEnabled = true;
      final int n = seg?.samples.length ?? 0;
      if (n < spec.required) return false;
    }
    return anyEnabled;
  }

  /// 参与计算的分段（剔除用户取消启用的分段）。
  static List<GbSegment> activeSegments(List<GbSegment> segments) =>
      <GbSegment>[
        for (final GbSegment s in segments)
          if (s.enabled) s,
      ];

  /// 该分段是否**真的有**可用于该验证项的数据（条数达标 + 浓度符合）。
  ///
  /// 用于 UI「进入页面时默认勾选哪些验证项」的判断。仅有条数是不够的：
  /// 单段项目（定量下限 target 0.02、24 h 低浓度漂移 target 0.1）在自动绑定
  /// 时会把全部行塞进唯一一段，只按条数判断会让「只有 0.8 mg/L 数据」的用户
  /// 默认勾上定量下限与漂移，算出一堆无意义的结论。
  ///
  /// - `discard` 段（记忆效应的前置 3 次 80%）：只要求有数据即可，
  ///   它反映的是「试验流程有没有走完」，不参与判定所以不校验浓度；
  /// - 无目标浓度的分段（一致性偏差）：只校验条数。
  static bool segmentUsable(GbSegmentSpec spec, GbSegment? segment) {
    if (segment == null) return false;
    if (spec.discard) return segment.samples.isNotEmpty;
    if (segment.samples.length < spec.required) return false;
    final double? target = spec.target;
    if (target == null || target <= 0) return true;
    final List<double> xs = segment.samples
        .take(spec.required)
        .map((GbSample s) => s.value)
        .toList();
    final double mean = _mean(xs);
    if (!mean.isFinite || mean <= 0) return false;
    return ((mean - target) / target).abs() <= concentrationMatchTolerance;
  }

  /// 是否覆盖了该项标准要求的**全部分段**。
  ///
  /// 第 9 轮起**只作为 UI 提示**使用（如「本次仅验证 1/4 档」），
  /// 不再参与判定：[compute] 按已测档位出结论，用户只测了其中一档且该档合格时，
  /// 结论就是合格，不会因为「没测满全部档位」而被降级为「无法判定」。
  static bool coverageComplete(
    String itemId,
    String rangeKey,
    List<GbSegment> segments,
  ) {
    final List<GbSegmentSpec> specs = segmentSpecs(itemId, rangeKey);
    if (specs.isEmpty) return true;
    for (int i = 0; i < specs.length; i++) {
      if (specs[i].discard) continue;
      final GbSegment? seg = i < segments.length ? segments[i] : null;
      if (seg != null && !seg.enabled) return false;
    }
    return true;
  }

  /// 已启用的分段数 / 应验证的分段数（用于「仅验证 1/4 档」这类提示）。
  static List<int> coverageCounts(
    String itemId,
    String rangeKey,
    List<GbSegment> segments,
  ) {
    final List<GbSegmentSpec> specs = segmentSpecs(itemId, rangeKey);
    int enabled = 0;
    int total = 0;
    for (int i = 0; i < specs.length; i++) {
      if (specs[i].discard) continue;
      total++;
      final GbSegment? seg = i < segments.length ? segments[i] : null;
      if (seg == null || seg.enabled) enabled++;
    }
    return <int>[enabled, total];
  }

  /// 该验证项在本量程下「标准规定应测的档位数」（不含 discard 前置段）。
  static int requiredTierCount(String itemId, String rangeKey) => segmentSpecs(
    itemId,
    rangeKey,
  ).where((GbSegmentSpec s) => !s.discard).length;

  /// 结论的档位覆盖后缀（第 9 轮 QA 顺延项 P2-3）。
  ///
  /// 口径：只测部分档位、已测档位全合格即可判合格；为避免读者误以为已覆盖
  /// 全部标准档位，在结论旁显式标注 `（n/m 档）`。不合格项已由逐档红色提示
  /// 指明具体档位，无需再加后缀；单档项目也不加，避免「（1/1 档）」噪音。
  static String tierCoverageSuffix(ItemReport report) {
    if (report.conclusion != GbConclusion.pass) return '';
    if (report.tiers.isEmpty) return '';
    final int required = requiredTierCount(report.itemId, report.rangeKey);
    if (required <= 0 || report.tiers.length >= required) return '';
    return '（${report.tiers.length}/$required 档）';
  }

  /// 选中总条数是否足以开始计算（至少要有 2 条才能得到统计量）。
  static bool enoughToCompute(List<GbSample> samples) => samples.length >= 2;

  // ---------------------------------------------------------------- 统一入口

  /// 计算一个验证项。
  ///
  /// 判定规则（第 9 轮起）：**按已测档位出结论**。
  /// - 任一**已启用**档位不合格 → 该项不合格；
  /// - 全部已启用档位合格 → 该项合格（不再因为「没测满标准要求的全部档位」
  ///   而强制降级为「无法判定」）；
  /// - 没有任何可算档位（全部停用 / 数据无法构成有效档位）→ 无法判定。
  ///
  /// 仍保留的唯一硬门槛是**条数门槛**：任一启用档位条数不足时不得出结论
  /// （见 [dataSufficient]），此时结论强制为「无法判定」并说明缺口。
  ///
  /// - [segments]：分段数据（顺序须与 [segmentSpecs] 一致）；
  /// - [labMean]：实际样品比对所需的实验室测定均值（mg/L）；
  /// - [maintenanceHours]：最小维护周期所需的两次维护间隔（h）；
  /// - [validCount]/[totalCount]：数据有效率的有效数与总数；
  /// - [limitOverride]：工作空间里用户自定义的判定限（仅本量程），
  ///   非空时替换 [item] 在该量程下的标准默认限值，其余字段不变。
  static ItemReport compute({
    required VerificationItem item,
    required String rangeKey,
    List<GbSegment> segments = const <GbSegment>[],
    double? labMean,
    double? maintenanceHours,
    int? validCount,
    int? totalCount,
    StandardItemLimit? limitOverride,
  }) {
    // 自定义判定限：仅替换本量程的限值，其余字段不变（可审计）。
    final VerificationItem effective = limitOverride == null
        ? item
        : item.copyWith(
            limitsByRange: <String, StandardItemLimit>{
              ...item.limitsByRange,
              rangeKey: limitOverride,
            },
          );
    final ItemReport raw = _computeRaw(
      item: effective,
      rangeKey: rangeKey,
      segments: segments,
      labMean: labMean,
      maintenanceHours: maintenanceHours,
      validCount: validCount,
      totalCount: totalCount,
    );
    // 数据量门槛强制拦截：条数不足时不得出具合格/不合格结论。
    // 保留逐步计算过程（可追溯），只把结论改为「无法判定」并追加原因。
    if (raw.conclusion == GbConclusion.notApplicable) return raw;
    if (!dataSufficient(effective.id, rangeKey, segments)) {
      final String problems = checkSegments(effective.id, rangeKey, segments);
      return raw.copyWith(
        conclusion: GbConclusion.notApplicable,
        dataNote: problems.isEmpty
            ? '数据量未达到标准要求，无法判定。'
            : '数据量未达到标准要求，无法判定：$problems',
      );
    }
    // 第 9 轮：此处原有的「覆盖不全 → 降级为无法判定」逻辑已删除。
    // 用户只测了部分档位时，按已测档位出结论（全部合格即合格），
    // 逐档明细见 ItemReport.tiers，覆盖情况由 UI 单独提示。
    return raw;
  }

  static ItemReport _computeRaw({
    required VerificationItem item,
    required String rangeKey,
    List<GbSegment> segments = const <GbSegment>[],
    double? labMean,
    double? maintenanceHours,
    int? validCount,
    int? totalCount,
  }) {
    // 用户取消勾选的分段不参与计算，也不产生「数据不足」提示。
    final List<GbSegment> active = activeSegments(segments);
    final int skipped = segments.length - active.length;
    final String problems = checkSegments(item.id, rangeKey, segments);
    final String dataNote = skipped == 0
        ? problems
        : <String>[
            if (problems.isNotEmpty) problems,
            '有 $skipped 个数据分段未参与计算（未勾选或数据量不足被自动停用），'
                '仅按已启用分段出结论',
          ].join('；');
    switch (item.id) {
      case 'indication_error':
        return _indicationError(item, rangeKey, active, dataNote);
      case 'loq':
        return _loq(item, rangeKey, active, dataNote);
      case 'repeatability':
        return _repeatability(item, rangeKey, active, dataNote);
      case 'drift_low24h':
        return _driftLow(item, rangeKey, active, dataNote);
      case 'drift_high24h':
        return _driftHigh(item, rangeKey, active, dataNote);
      case 'memory_80to20':
        return _memory(item, rangeKey, active, dataNote, '<');
      case 'memory_20to80':
        return _memory(item, rangeKey, active, dataNote, '>');
      case 'voltage':
        return _influence(
          item,
          rangeKey,
          active,
          dataNote,
          baseKey: 'v220',
          condKeys: const <String>['v242', 'v198'],
          condLabels: const <String>['242 V', '198 V'],
          baseLabel: '220 V',
        );
      case 'turbidity':
        return _influence(
          item,
          rangeKey,
          active,
          dataNote,
          baseKey: 't0',
          condKeys: const <String>['t100', 't300'],
          condLabels: const <String>['100 NTU', '300 NTU'],
          baseLabel: '无浊度',
        );
      case 'temperature':
        return _temperature(item, rangeKey, active, dataNote);
      case 'sample_compare':
        return _sampleCompare(item, rangeKey, active, dataNote, labMean);
      case 'maintenance':
        return _maintenance(item, rangeKey, maintenanceHours);
      case 'data_availability':
        return _dataAvailability(item, rangeKey, validCount, totalCount);
      case 'conformity':
        return _conformity(item, rangeKey, active, dataNote);
      default:
        return _na(item, rangeKey, '该验证项暂未实现计算。');
    }
  }

  // ---------------------------------------------------------------- 5.5.1.1 示值误差

  static ItemReport _indicationError(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无判定限。');
    final List<CalcStep> steps = <CalcStep>[];
    int no = 1;
    final List<List<String>> detail = <List<String>>[
      <String>['浓度档', '标准值ρ(mg/L)', '测定均值r̄(mg/L)', '次数', '相对误差RE(%)'],
    ];
    final List<GbTierResult> tiers = <GbTierResult>[];
    double maxAbs = 0;
    bool anyComputed = false;
    final List<String> sampleIds = <String>[];

    for (final GbSegment seg in segments) {
      final List<GbSample> used = seg.samples.take(6).toList();
      if (used.length < 2 || seg.target == null) continue;
      sampleIds.addAll(used.map((GbSample s) => s.id));
      final List<double> xs = used.map((GbSample s) => s.value).toList();
      final double mean = _mean(xs);
      final double re = (mean - seg.target!) / seg.target! * 100;
      anyComputed = true;
      if (re.abs() > maxAbs) maxAbs = re.abs();
      // 逐档判定：每一档单独与 ±限值比较，供结果页/导出逐档展示。
      tiers.add(
        GbTierResult(
          label: seg.label,
          valueText: _fmt(re, 2),
          unit: '%',
          limitText: '±${_fmt(limit.percent ?? 0, 0)}%',
          passed:
              _judge(
                item,
                rangeKey,
                re,
                limit.percent ?? 0,
                limit.higherIsFail,
              ) ==
              GbConclusion.pass,
        ),
      );

      steps.add(
        CalcStep(
          no: no++,
          title: '计算「${seg.label}」${used.length} 次测定值平均值',
          formula: 'r̄ = (r₁ + r₂ + … + rₙ) / n',
          substitution:
              '(${xs.map((double v) => _fmt(v, 4)).join(' + ')}) / ${used.length}',
          result: _fmt(mean, 4),
          unit: 'mg/L',
          note: 'n = ${used.length}，按标准每种溶液连续测定 6 次取平均值。',
        ),
      );
      steps.add(
        CalcStep(
          no: no++,
          title: '计算「${seg.label}」相对误差',
          formula: 'RE = (r̄ − ρ) / ρ × 100%',
          substitution:
              '(${_fmt(mean, 4)} − ${_fmt(seg.target!, 3)}) / '
              '${_fmt(seg.target!, 3)} × 100%',
          result: _fmt(re, 2),
          unit: '%',
          note: 'ρ 为该档标准溶液浓度值 ${_fmt(seg.target!, 3)} mg/L。',
        ),
      );
      detail.add(<String>[
        seg.label,
        _fmt(seg.target!, 3),
        _fmt(mean, 4),
        '${used.length}',
        _fmt(re, 2),
      ]);
    }

    if (!anyComputed) {
      return _na(item, rangeKey, '所选数据无法构成有效浓度档，请检查浓度是否与要求一致。');
    }

    steps.add(
      CalcStep(
        no: no++,
        title: '取各浓度相对误差的最大绝对值作为判定值',
        formula: 'RE_max = max(|RE_i|)',
        substitution: detail
            .skip(1)
            .map((List<String> r) => '|${r[4]}|')
            .join('、'),
        result: _fmt(maxAbs, 2),
        unit: '%',
        note: '标准规定取相对误差的最大值作为示值误差的判定值。',
      ),
    );

    final GbConclusion c = _judge(
      item,
      rangeKey,
      maxAbs,
      limit.percent ?? 0,
      limit.higherIsFail,
    );
    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: c,
      metricValue: maxAbs,
      metricDisplay: '${_fmt(maxAbs, 2)} %',
      limitDisplay: '±${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(maxAbs, limit.percent ?? 0),
      steps: steps,
      sampleIds: sampleIds,
      dataNote: dataNote,
      detailRows: detail,
      tiers: tiers,
    );
  }

  // ---------------------------------------------------------------- 5.5.1.2 定量下限

  static ItemReport _loq(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.absolute == null)
      return _na(item, rangeKey, '当前量程无定量下限要求。');
    final List<GbSample> used = segments.isEmpty
        ? const <GbSample>[]
        : segments.first.samples.take(7).toList();
    if (used.length < 2) return _na(item, rangeKey, '数据不足（至少 2 条）。');

    final List<double> xs = used.map((GbSample s) => s.value).toList();
    final double mean = _mean(xs);
    final double std = _std(xs);
    final double loq = 10 * std;
    final double target = segments.first.target ?? basicLower;
    final double re = target == 0 ? 0 : (mean - target) / target * 100;

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '计算 ${used.length} 次测定值平均值',
        formula: 'r̄ = (r₁ + r₂ + … + rₙ) / n',
        substitution:
            '(${xs.map((double v) => _fmt(v, 4)).join(' + ')}) / ${used.length}',
        result: _fmt(mean, 4),
        unit: 'mg/L',
        note: '低浓度重复测定，n = ${used.length}。',
      ),
      CalcStep(
        no: 2,
        title: '计算样本标准偏差 S',
        formula: 'S = √[Σ(rᵢ − r̄)² / (n − 1)]',
        substitution: '√[Σ(rᵢ − ${_fmt(mean, 4)})² / ${used.length - 1}]',
        result: _fmt(std, 5),
        unit: 'mg/L',
        note: '分母取 n−1（样本标准偏差）。',
      ),
      CalcStep(
        no: 3,
        title: '计算定量下限 LOQ',
        formula: 'LOQ = 10 × S',
        substitution: '10 × ${_fmt(std, 5)}',
        result: _fmt(loq, 4),
        unit: 'mg/L',
        note: '标准规定以 10 倍标准偏差作为定量下限。',
      ),
      CalcStep(
        no: 4,
        title: '校核该浓度示值误差',
        formula: 'RE = (r̄ − ρ) / ρ × 100%',
        substitution:
            '(${_fmt(mean, 4)} − ${_fmt(target, 3)}) / ${_fmt(target, 3)} × 100%',
        result: _fmt(re, 2),
        unit: '%',
        note: '在 0.02 mg/L 处示值误差应不超过 ±30%（标准表 1 备注）。',
      ),
    ];

    // 定量下限判定：LOQ ≤ 限值；同时示值误差须在 ±30% 内。
    final bool loqPass = loq <= (limit.absolute ?? 0);
    final bool rePass = re.abs() <= 30;
    final GbConclusion c = loqPass && rePass
        ? GbConclusion.pass
        : GbConclusion.fail;

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: c,
      metricValue: loq,
      metricDisplay: '${_fmt(loq, 3)} mg/L',
      limitDisplay: '≤${_fmt(limit.absolute ?? 0, 3)} mg/L（同浓度示值误差±30%）',
      ratio: _ratio(loq, limit.absolute ?? 0),
      steps: steps,
      sampleIds: used.map((GbSample s) => s.id).toList(),
      dataNote: dataNote,
      detailRows: <List<String>>[
        <String>['测定均值 r̄(mg/L)', '标准偏差 S', 'LOQ(mg/L)', '示值误差(%)'],
        <String>[_fmt(mean, 4), _fmt(std, 5), _fmt(loq, 4), _fmt(re, 2)],
      ],
      tiers: <GbTierResult>[
        GbTierResult(
          label: '定量下限 ${_fmt(target, 3)} mg/L（重复 ${used.length} 次）',
          valueText: _fmt(loq, 4),
          unit: 'mg/L',
          limitText: '≤${_fmt(limit.absolute ?? 0, 3)} mg/L',
          passed: c == GbConclusion.pass,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 5.5.1.3 重复性

  static ItemReport _repeatability(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无判定限。');
    final List<CalcStep> steps = <CalcStep>[];
    int no = 1;
    double maxRsd = 0;
    bool any = false;
    int computedCount = 0;
    final List<String> ids = <String>[];
    final List<GbTierResult> tiers = <GbTierResult>[];
    final List<List<String>> detail = <List<String>>[
      <String>['浓度档', '测定均值r̄(mg/L)', '标准偏差s', '次数', 'RSD(%)'],
    ];

    for (final GbSegment seg in segments) {
      final List<GbSample> used = seg.samples.take(6).toList();
      if (used.length < 2) continue;
      ids.addAll(used.map((GbSample s) => s.id));
      final List<double> xs = used.map((GbSample s) => s.value).toList();
      final double mean = _mean(xs);
      final double std = _std(xs);
      if (mean == 0) continue;
      final double rsd = std / mean.abs() * 100;
      any = true;
      computedCount++;
      if (rsd > maxRsd) maxRsd = rsd;
      // 逐档判定：每一档单独与 RSD 限值比较。
      tiers.add(
        GbTierResult(
          label: seg.label,
          valueText: _fmt(rsd, 2),
          unit: '%',
          limitText: '≤${_fmt(limit.percent ?? 0, 0)}%',
          passed:
              _judge(
                item,
                rangeKey,
                rsd,
                limit.percent ?? 0,
                limit.higherIsFail,
              ) ==
              GbConclusion.pass,
        ),
      );
      steps.add(
        CalcStep(
          no: no++,
          title: '计算「${seg.label}」${used.length} 次测定值平均值与标准偏差',
          formula: 'r̄ = Σrᵢ / n，S = √[Σ(rᵢ − r̄)² / (n − 1)]',
          substitution:
              'r̄ = (${xs.map((double v) => _fmt(v, 4)).join(' + ')}) / ${used.length}',
          result: 'r̄ = ${_fmt(mean, 4)}，S = ${_fmt(std, 5)}',
          unit: 'mg/L',
          note: 'n = ${used.length}。',
        ),
      );
      steps.add(
        CalcStep(
          no: no++,
          title: '计算「${seg.label}」相对标准偏差',
          formula: 'RSD = S / r̄ × 100%',
          substitution: '${_fmt(std, 5)} / ${_fmt(mean, 4)} × 100%',
          result: _fmt(rsd, 2),
          unit: '%',
          note: '重复性以相对标准偏差表示。',
        ),
      );
      detail.add(<String>[
        seg.label,
        _fmt(mean, 4),
        _fmt(std, 5),
        '${used.length}',
        _fmt(rsd, 2),
      ]);
    }

    if (!any) return _na(item, rangeKey, '所选数据不足以计算 RSD（需要每档至少 2 条）。');

    if (computedCount > 1) {
      steps.add(
        CalcStep(
          no: no++,
          title: '取较大值为判定值',
          formula: 'RSD = max(RSD_i)',
          substitution: detail.skip(1).map((List<String> r) => r[4]).join('、'),
          result: _fmt(maxRsd, 2),
          unit: '%',
          note: '标准规定取两种浓度相对标准偏差的较大值作为判定值。',
        ),
      );
    }

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: _judge(
        item,
        rangeKey,
        maxRsd,
        limit.percent ?? 0,
        limit.higherIsFail,
      ),
      metricValue: maxRsd,
      metricDisplay: '${_fmt(maxRsd, 2)} %',
      limitDisplay: '≤${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(maxRsd, limit.percent ?? 0),
      steps: steps,
      sampleIds: ids,
      dataNote: dataNote,
      detailRows: detail,
      tiers: tiers,
    );
  }

  // ---------------------------------------------------------------- 5.5.1.4 低浓度漂移

  static ItemReport _driftLow(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.absolute == null)
      return _na(item, rangeKey, '当前量程无该项要求。');
    final List<GbSample> used = segments.isEmpty
        ? const <GbSample>[]
        : segments.first.samples.take(24).toList();
    if (used.length < 4) return _na(item, rangeKey, '数据不足（至少 4 条）。');

    final List<double> xs = used.map((GbSample s) => s.value).toList();
    final List<double> head = xs.take(3).toList();
    final double r0 = _mean(head);
    double sumAbs = 0;
    final List<String> diffs = <String>[];
    for (final double v in xs) {
      final double d = (v - r0).abs();
      sumAbs += d;
      diffs.add(_fmt(d, 4));
    }
    final double drift = sumAbs / xs.length;

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '计算初期值 r̄₀（最初 3 次测定值平均值）',
        formula: 'r̄₀ = (r₁ + r₂ + r₃) / 3',
        substitution: '(${head.map((double v) => _fmt(v, 4)).join(' + ')}) / 3',
        result: _fmt(r0, 4),
        unit: 'mg/L',
        note: '标准规定以最初 3 次测定值的平均值作为初期值。',
      ),
      CalcStep(
        no: 2,
        title: '计算各次测定值与初期值的绝对偏差',
        formula: 'dᵢ = |rᵢ − r̄₀|',
        substitution: '共 ${xs.length} 次，r̄₀ = ${_fmt(r0, 4)}',
        result: 'Σdᵢ = ${_fmt(sumAbs, 4)}',
        unit: 'mg/L',
        note: '逐条与初期值比较，此处给出偏差之和（区间 ${diffs.first} ~ ${diffs.last}）。',
      ),
      CalcStep(
        no: 3,
        title: '计算 24 h 低浓度漂移',
        formula: 'r̄_E = Σ|rᵢ − r̄₀| / n',
        substitution: '${_fmt(sumAbs, 4)} / ${xs.length}',
        result: _fmt(drift, 4),
        unit: 'mg/L',
        note: '结果以绝对量表示，限值 ${_fmt(limit.absolute ?? 0, 3)} mg/L。',
      ),
    ];

    final GbConclusion lowConclusion = _judge(
      item,
      rangeKey,
      drift,
      limit.absolute ?? 0,
      limit.higherIsFail,
    );

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: lowConclusion,
      metricValue: drift,
      metricDisplay: '${_fmt(drift, 4)} mg/L',
      limitDisplay: '≤${_fmt(limit.absolute ?? 0, 3)} mg/L',
      ratio: _ratio(drift, limit.absolute ?? 0),
      steps: steps,
      sampleIds: used.map((GbSample s) => s.id).toList(),
      dataNote: dataNote,
      detailRows: <List<String>>[
        <String>['初期值 r̄₀(mg/L)', '测定次数 n', '漂移 r̄_E(mg/L)'],
        <String>[_fmt(r0, 4), '${xs.length}', _fmt(drift, 4)],
      ],
      tiers: <GbTierResult>[
        GbTierResult(
          label: '约 0.1 mg/L 连续 ${xs.length} h',
          valueText: _fmt(drift, 4),
          unit: 'mg/L',
          limitText: '≤${_fmt(limit.absolute ?? 0, 3)} mg/L',
          passed: lowConclusion == GbConclusion.pass,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 5.5.1.5 高浓度漂移

  static ItemReport _driftHigh(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无该项要求。');
    final List<GbSample> used = segments.isEmpty
        ? const <GbSample>[]
        : segments.first.samples.take(24).toList();
    if (used.length < 4) return _na(item, rangeKey, '数据不足（至少 4 条）。');

    final List<double> xs = used.map((GbSample s) => s.value).toList();
    final double r0 = _mean(xs.take(3).toList());
    double sumAbs = 0;
    for (final double v in xs) {
      sumAbs += (v - r0).abs();
    }
    final double meanDev = sumAbs / xs.length;
    final double rUl = upperLimitOf(rangeKey);
    final double rd = meanDev / rUl * 100;

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '计算初期值 r̄₀（最初 3 次测定值平均值）',
        formula: 'r̄₀ = (r₁ + r₂ + r₃) / 3',
        substitution:
            '(${xs.take(3).map((double v) => _fmt(v, 4)).join(' + ')}) / 3',
        result: _fmt(r0, 4),
        unit: 'mg/L',
        note: '与低浓度漂移相同，取最初 3 次平均值作为初期值。',
      ),
      CalcStep(
        no: 2,
        title: '计算测定值与初期值偏差绝对值的平均值',
        formula: 'Δ̄ = Σ|rᵢ − r̄₀| / n',
        substitution: '${_fmt(sumAbs, 4)} / ${xs.length}',
        result: _fmt(meanDev, 4),
        unit: 'mg/L',
        note: 'n = ${xs.length}（连续 24 h，每小时 1 次）。',
      ),
      CalcStep(
        no: 3,
        title: '换算为相对于检测范围上限的百分率',
        formula: 'RD = Δ̄ / r_UL × 100%',
        substitution: '${_fmt(meanDev, 4)} / ${_fmt(rUl, 1)} × 100%',
        result: _fmt(rd, 2),
        unit: '%',
        note: 'r_UL 为检测范围上限值 ${_fmt(rUl, 1)} mg/L。',
      ),
    ];

    final GbConclusion highConclusion = _judge(
      item,
      rangeKey,
      rd,
      limit.percent ?? 0,
      limit.higherIsFail,
    );

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: highConclusion,
      metricValue: rd,
      metricDisplay: '${_fmt(rd, 2)} %',
      limitDisplay: '≤${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(rd, limit.percent ?? 0),
      steps: steps,
      sampleIds: used.map((GbSample s) => s.id).toList(),
      dataNote: dataNote,
      detailRows: <List<String>>[
        <String>['初期值 r̄₀(mg/L)', '平均绝对偏差 Δ̄(mg/L)', '上限值 r_UL', 'RD(%)'],
        <String>[_fmt(r0, 4), _fmt(meanDev, 4), _fmt(rUl, 1), _fmt(rd, 2)],
      ],
      tiers: <GbTierResult>[
        GbTierResult(
          label:
              '上限值 80%（${mgL(upperLimitOf(rangeKey) * 0.8)}）连续 ${xs.length} h',
          valueText: _fmt(rd, 2),
          unit: '%',
          limitText: '≤${_fmt(limit.percent ?? 0, 0)}%',
          passed: highConclusion == GbConclusion.pass,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 5.5.1.6 记忆效应

  /// [direction] 为 '<' 表示 80%→20%（记忆残留拉高还是拉低由符号体现），
  /// 仅用于文案；两个方向的限值不同（±10% / ±5%）。
  static ItemReport _memory(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
    String direction,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无该项要求。');
    final List<GbSample> used = segments.isEmpty
        ? const <GbSample>[]
        : () {
            // 只取本方向对应的那一段（80%→20% 判 low 段，20%→80% 判 high 段），
            // 前置「不考核」的 3 次 80% 已在绑定阶段被切走，不会混进来。
            final String wantKey = direction == '<' ? 'low' : 'high';
            List<GbSample> picked = const <GbSample>[];
            for (final GbSegment s in segments) {
              if (s.key == wantKey) picked = s.samples;
            }
            return picked.take(7).toList();
          }();
    if (used.length < 3)
      return _na(item, rangeKey, '数据不足（需要 7 条：第 1 次 + 后 6 次）。');

    final List<double> xs = used.map((GbSample s) => s.value).toList();
    final double r1 = xs.first;
    final List<double> rest = xs.sublist(1);
    final double mean = _mean(rest);
    final double re = mean == 0 ? double.nan : (r1 - mean) / mean * 100;
    final String dirText = direction == '<' ? '80% → 20%' : '20% → 80%';

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '取第 1 次测定值 r₁',
        formula: 'r₁ = 该浓度首次测定值',
        substitution: 'r₁ = ${_fmt(r1, 4)}',
        result: _fmt(r1, 4),
        unit: 'mg/L',
        note: '$dirText 切换后该浓度溶液的第一次测定。',
      ),
      CalcStep(
        no: 2,
        title: '计算后 ${rest.length} 次测定值平均值 r̄',
        formula: 'r̄ = Σ(r₂…rₙ) / (n − 1)',
        substitution:
            '(${rest.map((double v) => _fmt(v, 4)).join(' + ')}) / ${rest.length}',
        result: _fmt(mean, 4),
        unit: 'mg/L',
        note: '标准规定以第 2 次起（共 n−1 次）的平均值作为基准。',
      ),
      CalcStep(
        no: 3,
        title: '计算记忆效应引起的相对误差',
        formula: 'RE₁ = (r₁ − r̄) / r̄ × 100%',
        substitution:
            '(${_fmt(r1, 4)} − ${_fmt(mean, 4)}) / ${_fmt(mean, 4)} × 100%',
        result: _fmt(re, 2),
        unit: '%',
        note: '$dirText 方向限值 ±${_fmt(limit.percent ?? 0, 0)}%。',
      ),
    ];

    final GbConclusion memConclusion = _judge(
      item,
      rangeKey,
      re,
      limit.percent ?? 0,
      limit.higherIsFail,
    );

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: memConclusion,
      metricValue: re,
      metricDisplay: '${_fmt(re, 2)} %',
      limitDisplay: '±${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(re, limit.percent ?? 0),
      steps: steps,
      sampleIds: used.map((GbSample s) => s.id).toList(),
      dataNote: dataNote,
      subLabel: dirText,
      detailRows: <List<String>>[
        <String>[
          '方向',
          '首次值 r₁(mg/L)',
          '后 ${rest.length} 次均值 r̄(mg/L)',
          'RE₁(%)',
        ],
        <String>[dirText, _fmt(r1, 4), _fmt(mean, 4), _fmt(re, 2)],
      ],
      tiers: <GbTierResult>[
        GbTierResult(
          label: '$dirText 方向（首次值对比后 ${rest.length} 次）',
          valueText: _fmt(re, 2),
          unit: '%',
          limitText: '±${_fmt(limit.percent ?? 0, 0)}%',
          passed: memConclusion == GbConclusion.pass,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 5.5.1.7~9 影响量

  static ItemReport _influence(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote, {
    required String baseKey,
    required List<String> condKeys,
    required List<String> condLabels,
    required String baseLabel,
  }) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无该项要求。');

    GbSegment? base;
    for (final GbSegment s in segments) {
      if (s.key == baseKey) base = s;
    }
    if (base == null || base.samples.length < 2) {
      return _na(item, rangeKey, '缺少「$baseLabel」条件下至少 2 条数据。');
    }
    final List<double> baseXs = base.samples
        .take(3)
        .map((GbSample s) => s.value)
        .toList();
    final double rBase = _mean(baseXs);

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '计算「$baseLabel」条件下 ${baseXs.length} 次测定值平均值 r_base',
        formula: 'r_base = (r₁ + r₂ + … + rₙ) / n',
        substitution:
            '(${baseXs.map((double v) => _fmt(v, 4)).join(' + ')}) / ${baseXs.length}',
        result: _fmt(rBase, 4),
        unit: 'mg/L',
        note: '作为基准条件（标准规定 220 V / 不含浊度 / 20 ℃）。',
      ),
    ];

    int no = 2;
    double maxAbs = 0;
    bool any = false;
    bool hasCond = false;
    final List<String> ids = <String>[
      ...base.samples.map((GbSample s) => s.id),
    ];
    final List<List<String>> detail = <List<String>>[
      <String>['条件', '测定均值(mg/L)', '次数', '相对误差(%)'],
    ];
    final List<GbTierResult> tiers = <GbTierResult>[
      GbTierResult(
        label: base.label,
        valueText: _fmt(rBase, 4),
        unit: 'mg/L',
        limitText: '基准',
        passed: true,
      ),
    ];
    detail.add(<String>[baseLabel, _fmt(rBase, 4), '${baseXs.length}', '—']);

    for (int i = 0; i < condKeys.length; i++) {
      GbSegment? seg;
      for (final GbSegment s in segments) {
        if (s.key == condKeys[i]) seg = s;
      }
      if (seg == null || seg.samples.length < 2) continue;
      final List<double> xs = seg.samples
          .take(3)
          .map((GbSample s) => s.value)
          .toList();
      final double m = _mean(xs);
      final double re = rBase == 0 ? double.nan : (m - rBase) / rBase * 100;
      hasCond = true;
      if (re.isFinite) {
        any = true;
        if (re.abs() > maxAbs) maxAbs = re.abs();
      }
      ids.addAll(seg.samples.map((GbSample s) => s.id));
      // 逐条件判定：每个影响量条件单独与该条件限值比较。
      tiers.add(
        GbTierResult(
          label: seg.label,
          valueText: _fmt(re, 2),
          unit: '%',
          limitText: '±${_fmt(limit.percent ?? 0, 0)}%',
          passed: re.isFinite
              ? _judge(
                      item,
                      rangeKey,
                      re,
                      limit.percent ?? 0,
                      limit.higherIsFail,
                    ) ==
                    GbConclusion.pass
              : false,
        ),
      );
      steps.add(
        CalcStep(
          no: no++,
          title: '计算「${condLabels[i]}」条件下 ${xs.length} 次平均值与相对误差',
          formula: 'RE = (r_cond − r_base) / r_base × 100%',
          substitution:
              '(${_fmt(m, 4)} − ${_fmt(rBase, 4)}) / ${_fmt(rBase, 4)} × 100%',
          result: _fmt(re, 2),
          unit: '%',
          note: 'r_cond = ${_fmt(m, 4)} mg/L。',
        ),
      );
      detail.add(<String>[
        condLabels[i],
        _fmt(m, 4),
        '${xs.length}',
        _fmt(re, 2),
      ]);
    }

    if (!hasCond) return _na(item, rangeKey, '缺少对比条件数据，无法计算影响量。');
    if (!any) {
      return _na(item, rangeKey, '「$baseLabel」条件测定均值为 0，无法计算相对误差。');
    }

    steps.add(
      CalcStep(
        no: no++,
        title: '取各条件相对误差绝对值的较大者',
        formula: 'RE_max = max(|RE_i|)',
        substitution: detail
            .skip(1)
            .where((List<String> r) => r[3] != '—')
            .map((List<String> r) => '|${r[3]}|')
            .join('、'),
        result: _fmt(maxAbs, 2),
        unit: '%',
        note: '标准规定取不同条件下相对误差绝对值的较大者作为判定值。',
      ),
    );

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: _judge(
        item,
        rangeKey,
        maxAbs,
        limit.percent ?? 0,
        limit.higherIsFail,
      ),
      metricValue: maxAbs,
      metricDisplay: '${_fmt(maxAbs, 2)} %',
      limitDisplay: '±${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(maxAbs, limit.percent ?? 0),
      steps: steps,
      sampleIds: ids,
      dataNote: dataNote,
      detailRows: detail,
      tiers: tiers,
    );
  }

  // ---------------------------------------------------------------- 5.5.1.9 温度

  static ItemReport _temperature(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无该项要求。');

    GbSegment? segOf(String key) {
      for (final GbSegment s in segments) {
        if (s.key == key) return s;
      }
      return null;
    }

    final List<GbSegment> t20 = <GbSegment>[
      for (final String k in <String>['t20a', 't20b', 't20c'])
        if (segOf(k) != null) segOf(k)!,
    ];
    if (t20.isEmpty) return _na(item, rangeKey, '缺少 20 ℃ 条件下的数据。');
    final List<double> t20xs = <double>[
      for (final GbSegment s in t20)
        ...s.samples.take(3).map((GbSample x) => x.value),
    ];
    if (t20xs.length < 2) return _na(item, rangeKey, '20 ℃ 条件数据不足。');
    final double r7 = _mean(t20xs);

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '计算 20 ℃ 条件 ${t20xs.length} 次测定值平均值 r₇',
        formula: 'r₇ = Σ(20℃各段测定值) / ${t20xs.length}',
        substitution:
            '(${t20xs.map((double v) => _fmt(v, 4)).join(' + ')}) / ${t20xs.length}',
        result: _fmt(r7, 4),
        unit: 'mg/L',
        note: '20 ℃ 共 3 段（初始→5 ℃→20 ℃→40 ℃→20 ℃ 中的 3 次回到 20 ℃），每段 3 次。',
      ),
    ];

    int no = 2;
    double maxAbs = 0;
    bool any = false;
    bool hasCond = false;
    final List<String> ids = <String>[
      for (final GbSegment s in t20) ...s.samples.map((GbSample x) => x.id),
    ];
    final List<List<String>> detail = <List<String>>[
      <String>['条件', '测定均值(mg/L)', '次数', '相对误差(%)'],
    ];
    detail.add(<String>['20 ℃（9 次）', _fmt(r7, 4), '${t20xs.length}', '—']);

    // 逐档判定：5 个温度段各一条。3 段 20 ℃ 是基准条件（不单独判定合格与否），
    // 5 ℃ 与 40 ℃ 才是被考核的条件段。
    final List<GbTierResult> tiers = <GbTierResult>[
      for (final GbSegment s in t20)
        GbTierResult(
          label: s.label,
          valueText: _fmt(
            _mean(s.samples.take(3).map((GbSample x) => x.value).toList()),
            4,
          ),
          unit: 'mg/L',
          limitText: '基准',
          passed: true,
        ),
    ];

    for (final MapEntry<String, String> e in <String, String>{
      't5': '5 ℃',
      't40': '40 ℃',
    }.entries) {
      final GbSegment? seg = segOf(e.key);
      if (seg == null || seg.samples.length < 2) continue;
      final List<double> xs = seg.samples
          .take(3)
          .map((GbSample s) => s.value)
          .toList();
      final double m = _mean(xs);
      final double re = r7 == 0 ? double.nan : (m - r7) / r7 * 100;
      hasCond = true;
      if (re.isFinite) {
        any = true;
        if (re.abs() > maxAbs) maxAbs = re.abs();
      }
      ids.addAll(seg.samples.map((GbSample s) => s.id));
      // 逐温度段判定：5 ℃ / 40 ℃ 各自与限值比较。
      tiers.add(
        GbTierResult(
          label: seg.label,
          valueText: _fmt(re, 2),
          unit: '%',
          limitText: '±${_fmt(limit.percent ?? 0, 0)}%',
          passed: re.isFinite
              ? _judge(
                      item,
                      rangeKey,
                      re,
                      limit.percent ?? 0,
                      limit.higherIsFail,
                    ) ==
                    GbConclusion.pass
              : false,
        ),
      );
      steps.add(
        CalcStep(
          no: no++,
          title: '计算「${e.value}」条件下 ${xs.length} 次平均值与相对误差',
          formula: 'RE = (r₆ − r₇) / r₇ × 100%',
          substitution:
              '(${_fmt(m, 4)} − ${_fmt(r7, 4)}) / ${_fmt(r7, 4)} × 100%',
          result: _fmt(re, 2),
          unit: '%',
          note: 'r₆ 为 ${e.value} 条件下 3 次测定值的平均值。',
        ),
      );
      detail.add(<String>[e.value, _fmt(m, 4), '${xs.length}', _fmt(re, 2)]);
    }

    if (!hasCond) return _na(item, rangeKey, '缺少 5 ℃ 或 40 ℃ 条件数据。');
    if (!any) {
      return _na(item, rangeKey, '20 ℃ 条件测定均值为 0，无法计算相对误差。');
    }

    steps.add(
      CalcStep(
        no: no++,
        title: '取绝对值较大者为判定值',
        formula: 'RE₄ = max(|RE_5℃|, |RE_40℃|)',
        substitution: detail
            .skip(1)
            .where((List<String> r) => r[3] != '—')
            .map((List<String> r) => '|${r[3]}|')
            .join('、'),
        result: _fmt(maxAbs, 2),
        unit: '%',
        note: '标准规定取不同温度条件下相对误差绝对值的较大者。',
      ),
    );

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: _judge(
        item,
        rangeKey,
        maxAbs,
        limit.percent ?? 0,
        limit.higherIsFail,
      ),
      metricValue: maxAbs,
      metricDisplay: '${_fmt(maxAbs, 2)} %',
      limitDisplay: '±${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(maxAbs, limit.percent ?? 0),
      steps: steps,
      sampleIds: ids,
      dataNote: dataNote,
      detailRows: detail,
      tiers: tiers,
    );
  }

  // ---------------------------------------------------------------- 5.5.1.10 实际样品比对

  static ItemReport _sampleCompare(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
    double? labMean,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null) return _na(item, rangeKey, '当前量程无该项要求。');
    if (labMean == null || labMean <= 0) {
      return _na(item, rangeKey, '请先录入实验室按 GB/T 11893 测定的平均值 r_R。');
    }
    final List<GbSample> used = segments.isEmpty
        ? const <GbSample>[]
        // 标准要求「连续测量不少于 10 次」，与 checkSegments 的提示保持一致：
        // 只取前 10 条参与计算，避免提示说「仅用前 10 条」却偷偷用了全部行。
        : () {
            List<GbSample> picked = const <GbSample>[];
            for (final GbSegment s in segments) {
              if (s.key == 'sample') picked = s.samples;
            }
            if (picked.isEmpty) picked = segments.first.samples;
            return picked.take(10).toList();
          }();
    if (used.length < 2) return _na(item, rangeKey, '数据不足（至少 2 条）。');

    final List<double> xs = used.map((GbSample s) => s.value).toList();
    final bool lowSide = labMean < compareSplit;

    double sumAbs = 0;
    for (final double v in xs) {
      sumAbs += (v - labMean).abs();
    }
    final double meanAbs = sumAbs / xs.length;
    final double metric = lowSide ? meanAbs : meanAbs / labMean * 100;

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '按实验室均值判定浓度分类',
        formula: 'r_R < 0.4 mg/L → 绝对误差；r_R ≥ 0.4 mg/L → 相对误差',
        substitution:
            'r_R = ${_fmt(labMean, 4)} mg/L ${lowSide ? '<' : '≥'} 0.4 mg/L',
        result: lowSide ? '采用绝对误差判定' : '采用相对误差判定',
        note:
            '浓度分类依据是实验室标准方法（GB/T 11893）测定值的平均值，'
            '不是仪器测定值。',
      ),
      CalcStep(
        no: 2,
        title: '计算各次测定值与实验室均值的绝对偏差之和',
        formula: 'Σ|rᵢ − r_R|',
        substitution: 'r_R = ${_fmt(labMean, 4)}，共 ${xs.length} 次',
        result: _fmt(sumAbs, 4),
        unit: 'mg/L',
        note: '逐条与实验室均值比较后取绝对值求和。',
      ),
      CalcStep(
        no: 3,
        title: lowSide ? '计算绝对误差平均值' : '计算相对误差平均值',
        formula: lowSide
            ? 'r̄_E = Σ|rᵢ − r_R| / n'
            : 'RE = [Σ|rᵢ − r_R| / n] / r_R × 100%',
        substitution: lowSide
            ? '${_fmt(sumAbs, 4)} / ${xs.length}'
            : '(${_fmt(sumAbs, 4)} / ${xs.length}) / ${_fmt(labMean, 4)} × 100%',
        result: _fmt(metric, lowSide ? 4 : 2),
        unit: lowSide ? 'mg/L' : '%',
        note: lowSide
            ? '低浓度档限值 ${_fmt(limit.absolute ?? 0, 3)} mg/L。'
            : '高浓度档限值 ${_fmt(limit.percent ?? 0, 0)}%。',
      ),
    ];

    final double limitValue = lowSide
        ? (limit.absolute ?? compareAbsoluteLimit)
        : (limit.percent ?? 10);
    final GbConclusion c = _judge(item, rangeKey, metric, limitValue, true);

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: c,
      metricValue: metric,
      metricDisplay: lowSide
          ? '${_fmt(metric, 3)} mg/L'
          : '${_fmt(metric, 2)} %',
      limitDisplay: lowSide
          ? '≤${_fmt(limit.absolute ?? 0, 3)} mg/L（r_R < 0.4 mg/L）'
          : '≤${_fmt(limit.percent ?? 0, 0)}%（r_R ≥ 0.4 mg/L）',
      ratio: _ratio(metric, limitValue),
      steps: steps,
      sampleIds: used.map((GbSample s) => s.id).toList(),
      dataNote: dataNote,
      subLabel: lowSide ? '浓度分类：绝对误差' : '浓度分类：相对误差',
      detailRows: <List<String>>[
        <String>['实验室均值 r_R(mg/L)', '浓度分类', '判定方式', '结果', '限值'],
        <String>[
          _fmt(labMean, 4),
          lowSide ? '< 0.4 mg/L' : '≥ 0.4 mg/L',
          lowSide ? '绝对误差' : '相对误差',
          lowSide ? '${_fmt(metric, 4)} mg/L' : '${_fmt(metric, 2)} %',
          lowSide
              ? '≤${_fmt(limit.absolute ?? 0, 3)} mg/L'
              : '≤${_fmt(limit.percent ?? 0, 0)}%',
        ],
      ],
      tiers: <GbTierResult>[
        GbTierResult(
          label:
              '实验室均值 ${_fmt(labMean, 4)} mg/L'
              '（${lowSide ? '绝对误差' : '相对误差'}）',
          valueText: lowSide ? _fmt(metric, 4) : _fmt(metric, 2),
          unit: lowSide ? 'mg/L' : '%',
          limitText: lowSide
              ? '≤${_fmt(limit.absolute ?? 0, 3)} mg/L'
              : '≤${_fmt(limit.percent ?? 0, 0)}%',
          passed: c == GbConclusion.pass,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 5.5.1.11 维护周期

  /// 最小维护周期：限值必须按 [rangeKey] 取，不能写死 'basic'。
  /// 否则扩展量程下用户自定义判定限会被静默忽略，且报告量程标错。
  static ItemReport _maintenance(
    VerificationItem item,
    String rangeKey,
    double? hours,
  ) {
    if (hours == null) {
      return _na(item, rangeKey, '请先录入两次维护之间的间隔小时数。');
    }
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    final double limitValue = limit?.absolute ?? 168;
    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '取相邻两次维护的最短间隔',
        formula: 'T = min(维护间隔_i)',
        substitution: '录入的各次维护间隔取最小值 T = ${_fmt(hours, 1)} h',
        result: _fmt(hours, 1),
        unit: 'h',
        note:
            '整个检测周期内任何 2 次维护（倾倒废液、添加试剂、更换量程及维修等）'
            '的间隔均应不小于 ${_fmt(limitValue, 0)} h；判定用其中的最小间隔。',
      ),
    ];
    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: _judge(
        item,
        rangeKey,
        hours,
        limitValue,
        limit?.higherIsFail ?? false,
      ),
      metricValue: hours,
      metricDisplay: '${_fmt(hours, 1)} h',
      // 限值文本必须跟着生效限值走：用户自定义判定限（如 ≥200 h）时
      // 若仍硬编码 ≥168 h，就会出现「按 200 h 判不合格、报告写 ≥168 h」的错位。
      limitDisplay: '≥${_fmt(limitValue, 0)} h',
      ratio: _ratio(hours, limitValue),
      steps: steps,
      subLabel: '最短维护间隔',
    );
  }

  // ---------------------------------------------------------------- 5.5.1.12 数据有效率

  /// 数据有效率：同 [_maintenance]，限值 / 量程标记必须按 [rangeKey] 取。
  static ItemReport _dataAvailability(
    VerificationItem item,
    String rangeKey,
    int? validCount,
    int? totalCount,
  ) {
    if (validCount == null || totalCount == null || totalCount <= 0) {
      return _na(item, rangeKey, '请先录入有效数据个数与应获得的总数据个数。');
    }
    // 防御：有效数不可能超过总数，否则会算出 >100% 并判「合格」。
    if (validCount > totalCount) {
      return _na(
        item,
        rangeKey,
        '有效数据个数（$validCount）不能大于应获得的总数据个数（$totalCount），'
        '请检查录入。',
      );
    }
    final double d = validCount / totalCount * 100;
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    final double limitValue = limit?.percent ?? 90;
    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '计算数据有效率',
        formula: 'D = D_e / D_t × 100%',
        substitution: '$validCount / $totalCount × 100%',
        result: _fmt(d, 2),
        unit: '%',
        note: 'D_e 为实际有效数据个数，D_t 为应获得的总数据个数。',
      ),
    ];
    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: _judge(item, rangeKey, d, limitValue, false),
      metricValue: d,
      metricDisplay: '${_fmt(d, 2)} %',
      limitDisplay: '≥${_fmt(limitValue, 0)}%',
      ratio: _ratio(d, limitValue),
      steps: steps,
      subLabel: '有效 $validCount / 总 $totalCount',
    );
  }

  // ---------------------------------------------------------------- 5.5.1.13 一致性偏差

  static ItemReport _conformity(
    VerificationItem item,
    String rangeKey,
    List<GbSegment> segments,
    String dataNote,
  ) {
    final StandardItemLimit? limit = item.limitFor(rangeKey);
    if (limit == null || limit.percent == null)
      return _na(item, rangeKey, '当前量程无该项要求。');

    final List<List<double>> rows = <List<double>>[];
    // 标准规定固定 3 台仪器同时测；多出的分段不参与（避免 RSD 分母变成 4 台）。
    for (final GbSegment s in segments.take(3)) {
      rows.add(s.samples.map((GbSample x) => x.value).toList());
    }
    if (rows.length < 3) {
      return _na(item, rangeKey, '一致性偏差需要 3 台仪器的数据（当前 ${rows.length} 组）。');
    }
    final int m = rows.map((List<double> r) => r.length).reduce(math.min);
    if (m < 2) return _na(item, rangeKey, '每台仪器至少需要 2 条数据。');

    final List<double> rsds = <double>[];
    final List<String> ids = <String>[];
    double maxRsd = 0;
    int overCount = 0;
    for (int j = 0; j < m; j++) {
      final List<double> slot = <double>[
        for (final List<double> r in rows) r[j],
      ];
      final double mean = _mean(slot);
      final double sd = _std(slot);
      final double rsd = mean == 0 ? 0 : sd / mean * 100;
      rsds.add(rsd);
      if (rsd > maxRsd) maxRsd = rsd;
      if (rsd > 10) overCount++;
    }
    for (int i = 0; i < 3; i++) {
      ids.addAll(segments[i].samples.take(m).map((GbSample s) => s.id));
    }

    double sumSq = 0;
    for (final double r in rsds) {
      sumSq += r * r;
    }
    final double cd = math.sqrt(sumSq / m);

    final List<CalcStep> steps = <CalcStep>[
      CalcStep(
        no: 1,
        title: '按时间段计算 3 台仪器的相对标准偏差 RSDⱼ',
        formula: 'RSDⱼ = √[Σ(ρᵢⱼ − ρ̄ⱼ)² / (t − 1)] / ρ̄ⱼ × 100%，t = 3',
        substitution: '共 ${m} 个时段，逐段计算',
        result: '最大 RSDⱼ = ${_fmt(maxRsd, 2)}',
        unit: '%',
        note: overCount > 0
            ? '有 $overCount 个时段 RSDⱼ > 10%，标准规定此时视为 CD > 10%。'
            : '各时段 RSDⱼ 均不超过 10%。',
      ),
      CalcStep(
        no: 2,
        title: '计算一致性偏差 CD',
        formula: 'CD = √[Σ RSDⱼ² / m]',
        substitution: '√[Σ(${m} 个 RSDⱼ²) / $m]',
        result: _fmt(cd, 2),
        unit: '%',
        note: 'm 为数据组数（标准取 168），限值 ${_fmt(limit.percent ?? 0, 0)}%。',
      ),
    ];

    final bool forced = overCount > 0;
    final GbConclusion c = forced
        ? GbConclusion.fail
        : _judge(item, rangeKey, cd, limit.percent ?? 0, limit.higherIsFail);

    // 逐台判定：3 台仪器各一条，记录该台测定均值；合格与否由联合的一致性偏差
    // CD 决定（标准要求 3 台同时测同一时段，单台无法独立判定）。
    final List<GbTierResult> tiers = <GbTierResult>[
      for (int i = 0; i < 3; i++)
        GbTierResult(
          label: segments[i].label,
          valueText: _fmt(
            _mean(
              segments[i].samples.take(m).map((GbSample x) => x.value).toList(),
            ),
            4,
          ),
          unit: 'mg/L',
          limitText: 'CD ≤${_fmt(limit.percent ?? 0, 0)}%',
          passed: c == GbConclusion.pass,
        ),
    ];

    return ItemReport(
      itemId: item.id,
      itemName: item.name,
      clause: item.clause,
      rangeKey: rangeKey,
      conclusion: c,
      metricValue: cd,
      metricDisplay: '${_fmt(cd, 2)} %',
      limitDisplay: '≤${_fmt(limit.percent ?? 0, 0)}%',
      ratio: _ratio(cd, limit.percent ?? 0),
      steps: steps,
      sampleIds: ids,
      dataNote: dataNote,
      subLabel: '$m 个时段 × 3 台仪器',
      detailRows: <List<String>>[
        <String>['时段数 m', '最大 RSDⱼ(%)', '超 10% 时段数', 'CD(%)'],
        <String>['$m', _fmt(maxRsd, 2), '$overCount', _fmt(cd, 2)],
      ],
      tiers: tiers,
    );
  }

  // ---------------------------------------------------------------- 工具

  /// 数值格式化：去掉多余的 0，固定 [d] 位小数。
  static String _fmt(double v, int d) {
    if (!v.isFinite) return '—';
    return v.toStringAsFixed(d);
  }

  /// 浓度展示（mg/L）。
  static String mgL(double v) {
    final String s = v.toStringAsFixed(v < 1 ? 2 : 1);
    return '$s mg/L';
  }

  static double _mean(List<double> xs) => xs.isEmpty
      ? double.nan
      : xs.reduce((double a, double b) => a + b) / xs.length;

  static double _std(List<double> xs) {
    if (xs.length < 2) return 0;
    final double m = _mean(xs);
    double s = 0;
    for (final double x in xs) {
      s += (x - m) * (x - m);
    }
    return math.sqrt(s / (xs.length - 1));
  }

  static double? _ratio(double metric, double limit) {
    if (!metric.isFinite || limit == 0) return null;
    return metric.abs() / limit.abs();
  }

  static GbConclusion _judge(
    VerificationItem item,
    String rangeKey,
    double metric,
    double limit,
    bool higherIsFail,
  ) {
    if (!metric.isFinite) return GbConclusion.notApplicable;
    final bool pass = higherIsFail
        ? metric.abs() <= limit.abs()
        : metric.abs() >= limit.abs();
    return pass ? GbConclusion.pass : GbConclusion.fail;
  }

  static ItemReport _na(
    VerificationItem item,
    String rangeKey,
    String reason,
  ) => ItemReport(
    itemId: item.id,
    itemName: item.name,
    clause: item.clause,
    rangeKey: rangeKey,
    conclusion: GbConclusion.notApplicable,
    dataNote: reason,
  );
}

/// 一个数据分段（对应一个浓度档或一个试验条件）。
class GbSegment {
  const GbSegment({
    required this.key,
    required this.label,
    required this.samples,
    this.target,
    this.enabled = true,
  });

  final String key;
  final String label;
  final List<GbSample> samples;
  final double? target;

  /// 该分段是否参与本次计算。
  ///
  /// 标准要求「每档连续 6 次」，但用户手上常常只有其中某一档的数据
  /// （例如只有 0.8 mg/L 的 6 条）。此时应允许用户只勾选有数据的那一档，
  /// 未勾选的档**不参与判定、也不产生「数据不足」提示**，
  /// 该项就只按已勾选的档出结论。
  final bool enabled;

  int get count => samples.length;

  GbSegment copyWith({List<GbSample>? samples, bool? enabled}) => GbSegment(
    key: key,
    label: label,
    samples: samples ?? this.samples,
    target: target,
    enabled: enabled ?? this.enabled,
  );
}

/// 分段要求（由 [GbCalculator.segmentSpecs] 生成，供 UI 展示与自动归类）。
class GbSegmentSpec {
  const GbSegmentSpec({
    required this.key,
    required this.label,
    required this.target,
    required this.required,
    this.unit = '',
    this.discard = false,
  });

  final String key;
  final String label;
  final double? target;

  /// 标准要求的条数。
  final int required;

  /// 关联单位（如 `h`），仅用于提示文案。
  final String unit;

  /// 该段是否为「标准规定要测但不参与判定」的前置段。
  ///
  /// 目前仅记忆效应使用：先连续测 3 次 80% 溶液，其测定结果不作考核，
  /// 但必须占用数据行（否则第 1 次与后 6 次均值会错位）。
  /// 前置段不参与数据量校验，也不影响「开始计算」的可用性。
  final bool discard;
}
