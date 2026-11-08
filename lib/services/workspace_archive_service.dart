import '../models/workspace.dart';
import 'workspace_store.dart';

/// 工具成果归档：把子工具产出的文件以自定义名保存到指定工作空间文件夹。
///
/// 所有「保存到工作空间」入口统一走这里，避免各页面直接操作文件系统。
class WorkspaceArchiveService {
  WorkspaceArchiveService({WorkspaceStore? store})
    : _store = store ?? WorkspaceStore();

  final WorkspaceStore _store;

  /// 归档单个文件，返回登记后的 [WorkspaceFile]。
  Future<WorkspaceFile> archive({
    required String workspaceId,
    required String sourcePath,
    required String customName,
  }) => _store.addFile(workspaceId, sourcePath, customName: customName);

  /// 批量归档（大肠杆菌计算三件套等），返回每个文件的登记结果。
  Future<List<WorkspaceFile>> archiveAll({
    required String workspaceId,
    required Map<String, String> sourcePathsByCustomName,
  }) async {
    final List<WorkspaceFile> out = <WorkspaceFile>[];
    for (final MapEntry<String, String> e in sourcePathsByCustomName.entries) {
      out.add(
        await archive(
          workspaceId: workspaceId,
          sourcePath: e.value,
          customName: e.key,
        ),
      );
    }
    return out;
  }
}
