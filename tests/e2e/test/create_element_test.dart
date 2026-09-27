/// `flutter test` 缺省只扫描包内 `test/` 子目录；本文件为转发入口，
/// 实现位于 §12.3 规定的 `../create_element_test.dart`（两处一一对应）。
library;

import '../create_element_test.dart' as impl;

void main() => impl.main();
