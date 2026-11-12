Pod::Spec.new do |s|
  s.name = 'ETOSInputArea'
  s.version = '0.0.0'
  s.summary = 'ETOS local Fabric input area host'
  s.description = s.summary
  s.license = { :type => 'UNLICENSED' }
  s.author = 'ETOS'
  s.homepage = 'https://github.com/expo/expo'
  # Expo autolinking supplies the local pod path; no remote source is fetched.
  s.source = { :git => 'file:///dev/null' }
  s.platforms = { :ios => '16.4' }
  s.swift_version = '5.9'
  s.dependency 'ExpoModulesCore'
  s.static_framework = true
  s.source_files = '**/*.swift'
end
