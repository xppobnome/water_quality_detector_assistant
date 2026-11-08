import 'package:flutter/material.dart';

import 'app.dart';
import 'services/storage_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final StorageService storage = StorageService();
  await storage.init();
  runApp(WaterQualityApp(storage: storage));
}
