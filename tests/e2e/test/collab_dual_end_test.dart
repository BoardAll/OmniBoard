/// `flutter test` 缺省只扫描包内 `test/` 子目录；本文件为转发入口，
/// 实现位于包根 `../collab_dual_end_test.dart`（两处一一对应）。
library;

import '../collab_dual_end_test.dart' as impl;

void main() => impl.main();
