import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';

import 'core/theme.dart';
import 'pages/shell_page.dart';
import 'providers/calculation_provider.dart';
import 'providers/image_to_excel_provider.dart';
import 'providers/transfer_provider.dart';
import 'providers/workspace_provider.dart';
import 'services/storage_service.dart';
import 'services/workspace_store.dart';

/// MaterialApp + 主题 + Provider 注册 + 导航壳。
class WaterQualityApp extends StatelessWidget {
  const WaterQualityApp({super.key, required this.storage});

  final StorageService storage;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <SingleChildWidget>[
        Provider<StorageService>.value(value: storage),
        // 全应用共用同一个 WorkspaceStore 实例（文件夹式落盘 + 回收站）。
        Provider<WorkspaceStore>(create: (_) => WorkspaceStore()),
        ChangeNotifierProvider<WorkspaceProvider>(
          create: (BuildContext ctx) =>
              WorkspaceProvider(store: ctx.read<WorkspaceStore>()),
        ),
        ChangeNotifierProvider<ImageToExcelProvider>(
          create: (_) => ImageToExcelProvider(storage: storage),
        ),
        ChangeNotifierProvider<CalculationProvider>(
          create: (_) => CalculationProvider(storage: storage),
        ),
        ChangeNotifierProvider<TransferProvider>(
          create: (_) => TransferProvider(),
        ),
      ],
      child: MaterialApp(
        title: '水质检测仪助手',
        theme: buildAppTheme(),
        debugShowCheckedModeBanner: false,
        home: const ShellPage(),
      ),
    );
  }
}
