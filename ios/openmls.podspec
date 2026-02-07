Pod::Spec.new do |s|
  s.name             = 'openmls'
  s.version          = '1.0.0'
  s.summary          = 'Dart wrapper for OpenMLS — a Rust implementation of the Messaging Layer Security (MLS) protocol (RFC 9420)'
  s.description      = <<-DESC
Dart wrapper for OpenMLS — a Rust implementation of the Messaging Layer Security (MLS) protocol (RFC 9420)
Native libraries are bundled automatically via Flutter's native assets system.
                       DESC
  s.homepage         = 'https://github.com/djx-y-z/openmls_dart'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'openmls' => 'dev@openmls.org' }
  s.source           = { :path => '.' }

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.swift_version = '5.0'
end
