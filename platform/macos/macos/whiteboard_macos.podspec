#
# Whiteboard macOS 平台插件（CocoaPods）。
#
# 与 pubspec.yaml 固化的 pluginClass（WhiteboardMacosPlugin）配套；
# 源文件位于 Classes/ 下（Objective-C++，Window/Overlay/Hotkey/Tray/Capture）。
# 集成方式：宿主（apps/desktop 的 macOS runner）通过 Flutter 插件的
# 标准 CocoaPods 流程自动引入，勿手动修改 pluginClass 声明。
#
Pod::Spec.new do |s|
  s.name             = 'whiteboard_macos'
  s.version          = '1.0.0'
  s.summary          = 'Whiteboard macOS platform plugin: window / hotkey / tray / screen capture.'
  s.description      = <<-DESC
提供窗口透明 / 置顶 / 点击穿透 / 全屏 / 位置尺寸、Carbon 全局快捷键、
NSStatusBar 托盘与 CGDisplayCreateImage 屏幕捕获的 macOS 原生实现。
                       DESC
  s.homepage         = 'https://example.com/whiteboard'
  s.license          = { :type => 'MIT', :text => 'Copyright (c) 2026 Whiteboard project.' }
  s.author           = { 'Whiteboard' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.14'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
  }
end
