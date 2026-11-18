# 高德 SDK 只能通过 CocoaPods 接入（官方未提供 SPM 包）。
# CI 流程：xcodegen generate → pod install → 用 SmartDash.xcworkspace 编译。
# 注意：不要加 use_frameworks!，高德是静态库，frameworks 化会导致链接失败。

platform :ios, '16.0'
install! 'cocoapods', :integrate_targets => true
inhibit_all_warnings!

target 'SmartDash' do
  # 导航 SDK（已内含 3D 地图，无需再引 AMap3DMap）
  pod 'AMapNavi'
  # POI 搜索 / 输入联想
  pod 'AMapSearch'
  # 定位（导航过程需要持续高精度定位）
  pod 'AMapLocation'
  # 车队语音对讲（WebRTC SFU；静态库方式集成，与高德共存）
  pod 'LiveKit', '~> 2.0'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |c|
      c.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
      c.build_settings['ENABLE_BITCODE'] = 'NO'
      # 高德 SDK 未适配 arm64 模拟器切片，CI 只编真机，这里保持默认即可
    end
  end
end
