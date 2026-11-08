import 'water_quality_row.dart';

/// 识别后勾选态（方案 B：裁剪 + 勾选行列/单元格都要）。
///
/// 导出/归档只保留勾选的内容。
/// 语义约定：空集合 = 未显式选择，视为全选；[noneSelected] = 一行都不选。
class TableSelection {
  TableSelection({
    Set<String>? selectedRowIds,
    Set<String>? selectedColumns,
    bool noneSelected = false,
  }) : selectedRowIds = selectedRowIds ?? <String>{},
       selectedColumns = selectedColumns ?? <String>{},
       noneSelected = noneSelected;

  /// 勾选行 id（空 = 全选）。
  final Set<String> selectedRowIds;

  /// 勾选列名（空 = 全选）。
  final Set<String> selectedColumns;

  /// 单元格级排除：rowId -> 被排除的列名集合（用于剔除某行中的个别单元格）。
  final Map<String, Set<String>> excludedCells = <String, Set<String>>{};

  /// 「一行都不选」标志。
  ///
  /// 空 [selectedRowIds] 已表示「全选」，无法表达「0 行」，故用独立标志；
  /// 为 true 时 [isRowSelected] / [isCellSelected] 恒为 false，
  /// [apply] 返回空列表。表头「反选」即通过它实现清空勾选。
  bool noneSelected;

  /// 深拷贝一份，供 UI 修改后回写（避免原地修改父级对象）。
  TableSelection clone() {
    final TableSelection next = TableSelection(
      selectedRowIds: Set<String>.from(selectedRowIds),
      selectedColumns: Set<String>.from(selectedColumns),
      noneSelected: noneSelected,
    );
    for (final MapEntry<String, Set<String>> e in excludedCells.entries) {
      next.excludedCells[e.key] = Set<String>.from(e.value);
    }
    return next;
  }

  void toggleRow(String rowId, bool on) {
    if (on) {
      noneSelected = false;
      selectedRowIds.add(rowId);
    } else {
      selectedRowIds.remove(rowId);
    }
  }

  void toggleColumn(String column, bool on) {
    if (on) {
      selectedColumns.add(column);
    } else {
      selectedColumns.remove(column);
    }
  }

  /// [on] = true 表示勾选（包含）该单元格；false 表示排除该单元格。
  void toggleCell(String rowId, String column, bool on) {
    final Set<String> excluded = excludedCells[rowId] ?? <String>{};
    if (on) {
      excluded.remove(column);
    } else {
      excluded.add(column);
    }
    if (excluded.isEmpty) {
      excludedCells.remove(rowId);
    } else {
      excludedCells[rowId] = excluded;
    }
  }

  bool isRowSelected(String rowId) {
    if (noneSelected) return false;
    return selectedRowIds.isEmpty || selectedRowIds.contains(rowId);
  }

  bool isColumnSelected(String column) =>
      selectedColumns.isEmpty || selectedColumns.contains(column);

  bool isCellSelected(String rowId, String column) =>
      isRowSelected(rowId) &&
      isColumnSelected(column) &&
      !(excludedCells[rowId]?.contains(column) ?? false);

  /// 应用到行列表：过滤未勾选行，并从 cells 剔除未勾选列与排除的单元格。
  ///
  /// [headers] 为当前仪器类型的列顺序；结果行保留原 id，便于去重与追溯。
  List<WaterQualityRow> apply(
    List<WaterQualityRow> rows,
    List<String> headers,
  ) {
    final List<WaterQualityRow> out = <WaterQualityRow>[];
    for (final WaterQualityRow row in rows) {
      if (!isRowSelected(row.id)) continue;
      final Map<String, String> cells = <String, String>{};
      for (final String h in headers) {
        if (!isColumnSelected(h)) continue;
        if (!isCellSelected(row.id, h)) continue;
        cells[h] = row.cells[h] ?? '';
      }
      out.add(
        WaterQualityRow.fromCells(
          instrument: row.instrument,
          cells: cells,
          id: row.id,
        ),
      );
    }
    return out;
  }
}
