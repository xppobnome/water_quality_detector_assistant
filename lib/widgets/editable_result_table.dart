import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../models/instrument_type.dart';
import '../models/table_selection.dart';
import '../models/water_quality_row.dart';
import '../utils/table_column_width.dart';

/// 可编辑识别结果表格 + 勾选行 / 列 / 单元格。
///
/// - 首列复选框：勾选整行；
/// - 表头复选框：勾选整列；
/// - 单元格右侧（行内垂直居中）小勾选框：单独排除 / 包含某个单元格；
/// 未传入 [selection] 时退化为原来的纯编辑表格。
class EditableResultTable extends StatefulWidget {
  const EditableResultTable({
    super.key,
    required this.rows,
    required this.instrument,
    required this.onCellChanged,
    this.onRemoveRow,
    this.selection,
    this.onRowToggle,
    this.onColumnToggle,
    this.onCellToggle,
    this.onSelectAll,
    this.allSelected = false,
  });

  final List<WaterQualityRow> rows;
  final InstrumentType instrument;
  final void Function(String rowId, String column, String value) onCellChanged;
  final void Function(String rowId)? onRemoveRow;

  final TableSelection? selection;
  final void Function(String rowId, bool on)? onRowToggle;
  final void Function(String column, bool on)? onColumnToggle;
  final void Function(String rowId, String column, bool on)? onCellToggle;

  /// 表头按钮回调，参数为「期望的新状态」：true=全选，false=清空/反选。
  final void Function(bool selectAll)? onSelectAll;

  /// 当前是否全选，用于切换表头按钮文案「全选」/「反选」。
  final bool allSelected;

  @override
  State<EditableResultTable> createState() => _EditableResultTableState();
}

class _EditableResultTableState extends State<EditableResultTable> {
  final Map<String, TextEditingController> _controllers =
      <String, TextEditingController>{};

  bool get _selectable => widget.selection != null;

  String _key(String rowId, String column) => '$rowId::$column';

  TextEditingController _controllerFor(
    String rowId,
    String column,
    String value,
  ) {
    final String key = _key(rowId, column);
    TextEditingController? controller = _controllers[key];
    if (controller == null) {
      controller = TextEditingController(text: value);
      _controllers[key] = controller;
    }
    return controller;
  }

  @override
  void didUpdateWidget(covariant EditableResultTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    for (final WaterQualityRow row in widget.rows) {
      for (final String header in widget.instrument.headers) {
        final TextEditingController? controller =
            _controllers[_key(row.id, header)];
        final String value = row.cells[header] ?? '';
        if (controller != null && controller.text != value) {
          controller.text = value;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final TextEditingController controller in _controllers.values) {
      controller.dispose();
    }
    _controllers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<String> headers = widget.instrument.headers;
    if (widget.rows.isEmpty) return const SizedBox.shrink();
    final TableSelection? selection = widget.selection;
    final Map<String, double> widths = <String, double>{
      for (final String header in headers)
        header: tableColumnWidth(header, widget.rows, selectable: _selectable),
    };

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SingleChildScrollView(
        child: DataTable(
          columnSpacing: 12,
          columns: <DataColumn>[
            if (_selectable)
              DataColumn(
                label: TextButton(
                  onPressed: widget.onSelectAll == null
                      ? null
                      : () => widget.onSelectAll!(!widget.allSelected),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    minimumSize: const Size(44, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    widget.allSelected ? '反选' : '全选',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            for (final String header in headers)
              DataColumn(
                label: SizedBox(
                  width: widths[header],
                  child: _selectable
                      ? Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            SizedBox(
                              width: 24,
                              height: 24,
                              child: Checkbox(
                                value: selection!.isColumnSelected(header),
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                onChanged: (bool? v) => widget.onColumnToggle
                                    ?.call(header, v ?? false),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                header,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ],
                        )
                      : Text(
                          header,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                ),
              ),
            if (widget.onRemoveRow != null) const DataColumn(label: Text('操作')),
          ],
          rows: <DataRow>[
            for (final WaterQualityRow row in widget.rows)
              DataRow(
                color: (_selectable && !selection!.isRowSelected(row.id))
                    ? WidgetStateProperty.all<Color?>(Colors.grey.shade100)
                    : null,
                cells: <DataCell>[
                  if (_selectable)
                    DataCell(
                      Checkbox(
                        value: selection!.isRowSelected(row.id),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        onChanged: (bool? v) =>
                            widget.onRowToggle?.call(row.id, v ?? false),
                      ),
                    ),
                  for (final String header in headers)
                    DataCell(
                      SizedBox(
                        width: widths[header],
                        height: 46,
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: <Widget>[
                            Expanded(
                              child: Tooltip(
                                message: row.cells[header] ?? '',
                                child: TextField(
                                  controller: _controllerFor(
                                    row.id,
                                    header,
                                    row.cells[header] ?? '',
                                  ),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 8,
                                    ),
                                  ),
                                  onChanged: (String value) => widget
                                      .onCellChanged(row.id, header, value),
                                ),
                              ),
                            ),
                            if (_selectable)
                              SizedBox(
                                width: 24,
                                height: 46,
                                child: Center(
                                  // 与输入框在同一 Row 中垂直居中，不再贴底。
                                  child: Tooltip(
                                    message:
                                        selection!.isCellSelected(
                                          row.id,
                                          header,
                                        )
                                        ? '排除该单元格'
                                        : '包含该单元格',
                                    child: GestureDetector(
                                      onTap: () => widget.onCellToggle?.call(
                                        row.id,
                                        header,
                                        !selection.isCellSelected(
                                          row.id,
                                          header,
                                        ),
                                      ),
                                      child: Icon(
                                        selection.isCellSelected(row.id, header)
                                            ? Icons.check_box_outlined
                                            : Icons.check_box_outline_blank,
                                        size: 18,
                                        color:
                                            selection.isCellSelected(
                                              row.id,
                                              header,
                                            )
                                            ? kPrimaryColor
                                            : kNeutralGrey,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  if (widget.onRemoveRow != null)
                    DataCell(
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: '删除该行',
                        onPressed: () => widget.onRemoveRow!(row.id),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
