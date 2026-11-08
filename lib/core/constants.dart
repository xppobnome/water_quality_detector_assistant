import 'package:flutter/material.dart';

/// 全局常量：配色、协议、默认参数、响应式断点。
///
/// 命名遵循共享知识约定：SCREAMING_SNAKE_CASE + `k` 前缀。
const Color kPrimaryColor = Color(0xFF1976D2);
const Color kPrimaryLight = Color(0xFFE3F2FD);

/// 语义状态色：成功 / 警示 / 错误。
const Color kSuccessColor = Color(0xFF2E7D32);
const Color kWarningColor = Color(0xFFEF6C00);
const Color kErrorColor = Color(0xFFC62828);
const Color kNeutralGrey = Color(0xFF9E9E9E);

/// 标液浓度默认值（MPN/L）。
const double kDefaultConcentration = 9000.0;
const String kDefaultUnit = 'MPN/L';

/// 数据传输协议常量。
const String kServiceTag = 'WQA';
const String kProtocolVersion = '1.0';
const int kTokenLength = 8;

/// HTTP 服务器优先端口，占用时动态回退。
const int kHttpPortPreferred = 54000;

/// UDP 广播发现端口。
const int kUdpDiscoveryPort = 54001;

/// 响应式布局断点：宽度 >= 该值使用桌面端（NavigationRail）布局。
const double kDesktopBreakpoint = 640.0;

/// 工作空间元数据文件名。
const String kWorkspaceMetaName = 'meta.json';

/// 回收站保留天数（超过该天数自动清理）。
const int kTrashRetentionDays = 30;
