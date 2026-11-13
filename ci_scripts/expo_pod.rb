# Use the same locked dependency graph in local preparation and Xcode Cloud.
ENV['BUNDLE_GEMFILE'] = File.expand_path('../expo-client/Gemfile', __dir__)
ENV['BUNDLE_FROZEN'] = 'true'
gem 'bundler', '= 2.4.22'
require 'bundler/setup'

# Activate the serializer before CocoaPods or its dependencies can require JSON.
gem 'json', '= 2.7.1'
require 'json'

pod_version = ARGV.shift or abort 'missing CocoaPods version'
gem 'cocoapods', "= #{pod_version}"
warn "CocoaPods #{pod_version}, Ruby #{RUBY_VERSION} (#{RbConfig.ruby}), Bundler #{Bundler::VERSION}, JSON #{JSON::VERSION}"
load Gem.bin_path('cocoapods', 'pod', pod_version)
