# Activate the serializer before CocoaPods or its dependencies can require JSON.
gem 'json', '= 2.7.1'
require 'json'

pod_version = ARGV.shift or abort 'missing CocoaPods version'
gem 'cocoapods', "= #{pod_version}"
warn "CocoaPods Ruby #{RUBY_VERSION} (#{RbConfig.ruby}), JSON #{JSON::VERSION}"
load Gem.bin_path('cocoapods', 'pod', pod_version)
