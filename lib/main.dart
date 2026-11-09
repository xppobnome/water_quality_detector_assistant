import 'package:flutter/material.dart';

import 'app.dart';
import 'services/storage_service.dart';
import 'services/workspace_storage_settings.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final StorageService storage = StorageService();
  await storage.init();
  // 工作空间存储位置偏好：必须在首次访问 WorkspaceStore 之前载入，
  // 否则会先用默认（应用文档目录）建目录、之后再被覆盖。
  await WorkspaceStorageSettings.load();
  runApp(WaterQualityApp(storage: storage));
}
