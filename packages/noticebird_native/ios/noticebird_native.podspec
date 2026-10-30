#
# CocoaPods build of the iOS collector. Swift Package Manager builds the same
# sources from noticebird_native/Package.swift; here the Foundation-only
# NativeCrashNormalizer package (normalizer, store, collector) and the plugin
# compile into this one pod, which is why the plugin imports it only under
# `#if canImport(NativeCrashNormalizer)`.
#
Pod::Spec.new do |s|
  s.name             = 'noticebird_native'
  s.version          = '0.5.0'
  s.summary          = 'Native crash capture for noticebird: iOS MetricKit diagnostics.'
  s.description      = <<-DESC
Collects MetricKit crash, hang and disk-write diagnostics of earlier runs,
minimizes them on the device and hands them to noticebird as bounded
records.
                       DESC
  s.homepage         = 'https://github.com/noticebird/noticebird-dart'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Noticebird SDK'
  s.source           = { :path => '.' }
  s.source_files     = [
    'noticebird_native/Sources/noticebird_native/**/*.swift',
    'noticebird_native/NativeCrashNormalizer/Sources/NativeCrashNormalizer/**/*.swift',
  ]
  s.resource_bundles = {
    'noticebird_native_privacy' => ['noticebird_native/Sources/noticebird_native/PrivacyInfo.xcprivacy']
  }
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'
  s.frameworks       = 'MetricKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
