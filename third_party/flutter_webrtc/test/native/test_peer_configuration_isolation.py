"""Compile production desktop peer creation/parsing against the bundled SDK.

Only the factory/Flutter messaging are doubles. RTCConfiguration, including its
defaults and TURN credential storage, is the actual bundled SDK type. No peer,
audio session, network socket, device or Flutter build is started.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

PLUGIN = Path(__file__).resolve().parents[2]


def method(source, signature):
    start = source.index(signature)
    cursor = source.index('{', start)
    depth, end = 1, cursor + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


HARNESS = r'''
#include <flutter/encodable_value.h>
#include "rtc_types.h"
#include <cassert>
#include <iostream>
#include <memory>
using namespace flutter;
using namespace libwebrtc;
template <typename T> bool TypeIs(const EncodableValue value) { return std::holds_alternative<T>(value); }
template <typename T> const T GetValue(EncodableValue value) { return std::get<T>(value); }
class RTCPeerConnection : public RefCountInterface {};
class RTCMediaConstraints : public RefCountInterface {};
struct Factory {
  std::vector<RTCConfiguration> configurations;
  scoped_refptr<RTCPeerConnection> Create(const RTCConfiguration& configuration, scoped_refptr<RTCMediaConstraints>) {
    configurations.push_back(configuration); return nullptr;
  }
};
class MethodResultProxy {
 public: void Success(const EncodableValue&) {}
};
class FlutterWebRTCBase;
class FlutterPeerConnectionObserver {
 public: FlutterPeerConnectionObserver(FlutterWebRTCBase*, scoped_refptr<RTCPeerConnection>, void*, void*, std::string, std::string) {}
};
class FlutterWebRTCBase {
 public:
  RTCConfiguration configuration_;
  Factory* factory_;
  void* messenger_ = nullptr;
  void* task_runner_ = nullptr;
  std::map<std::string, scoped_refptr<RTCPeerConnection>> peerconnections_;
  std::map<std::string, std::unique_ptr<FlutterPeerConnectionObserver>> peerconnection_observers_;
  bool CreateIceServers(const EncodableList&, IceServer*);
  bool ParseRTCConfiguration(const EncodableMap&, RTCConfiguration&);
  scoped_refptr<RTCMediaConstraints> ParseMediaConstraints(const EncodableMap&) { return nullptr; }
  std::string GenerateUUID() { return std::to_string(peerconnections_.size()); }
};
class FlutterPeerConnection {
 public:
  explicit FlutterPeerConnection(FlutterWebRTCBase* base) : base_(base) {}
  FlutterWebRTCBase* base_;
  void CreateRTCPeerConnection(const EncodableMap&, const EncodableMap&, std::unique_ptr<MethodResultProxy>);
};
// PARSE_ICE
// PARSE_CONFIG
// CREATE_PEER
EncodableMap Usb(int servers, const char* secret) {
  EncodableList list;
  for (int index = 0; index < servers; ++index) {
    list.emplace_back(EncodableMap{
      {EncodableValue("urls"), EncodableValue(EncodableList{EncodableValue("turn:127.0.0.1:50000?transport=tcp")})},
      {EncodableValue("username"), EncodableValue(secret)},
      {EncodableValue("credential"), EncodableValue(secret)}});
  }
  return {{EncodableValue("iceServers"), EncodableValue(list)},
          {EncodableValue("iceTransportPolicy"), EncodableValue("relay")}};
}
int main() {
  Factory factory;
  FlutterWebRTCBase base;
  base.factory_ = &factory;
  FlutterPeerConnection api(&base);
  api.CreateRTCPeerConnection(Usb(8, "old-usb-credential"), {}, std::make_unique<MethodResultProxy>());
  api.CreateRTCPeerConnection(Usb(1, "new-usb-credential"), {}, std::make_unique<MethodResultProxy>());
  api.CreateRTCPeerConnection({{EncodableValue("iceServers"), EncodableValue(EncodableList{})}}, {}, std::make_unique<MethodResultProxy>());
  assert(factory.configurations.size() == 3);
  assert(factory.configurations[0].type == IceTransportsType::kRelay);
  assert(factory.configurations[0].ice_servers[7].password.std_string() == "old-usb-credential");
  assert(factory.configurations[1].ice_servers[0].password.std_string() == "new-usb-credential");
  for (int index = 1; index < kMaxIceServerSize; ++index) {
    assert(factory.configurations[1].ice_servers[index].uri.std_string().empty());
    assert(factory.configurations[1].ice_servers[index].username.std_string().empty());
    assert(factory.configurations[1].ice_servers[index].password.std_string().empty());
  }
  assert(factory.configurations[2].type == IceTransportsType::kAll);
  for (const auto& server : factory.configurations[2].ice_servers) {
    assert(server.uri.std_string().empty());
    assert(server.username.std_string().empty());
    assert(server.password.std_string().empty());
  }
  std::cout << "Production create/parse: USB(8 servers) -> USB(1) -> LAN; no stale policy or credentials.\n";
}
'''


@unittest.skipUnless(os.name == 'nt', 'Windows bundled SDK contract')
class PeerConfigurationIsolationTest(unittest.TestCase):
    def test_production_create_resets_sdk_configuration(self):
        flutter = shutil.which('flutter')
        self.assertIsNotNone(flutter, 'Flutter SDK must be on PATH')
        flutter_root = Path(flutter).resolve().parents[1]
        sdk = PLUGIN / 'third_party/libwebrtc'
        source = HARNESS
        base = (PLUGIN / 'common/cpp/src/flutter_webrtc_base.cc').read_text()
        peer = (PLUGIN / 'common/cpp/src/flutter_peerconnection.cc').read_text()
        for marker, content, signature in [
            ('// PARSE_ICE', base, 'bool FlutterWebRTCBase::CreateIceServers('),
            ('// PARSE_CONFIG', base, 'bool FlutterWebRTCBase::ParseRTCConfiguration('),
            ('// CREATE_PEER', peer, 'void FlutterPeerConnection::CreateRTCPeerConnection('),
        ]:
            source = source.replace(marker, method(content, signature))
        with tempfile.TemporaryDirectory(prefix='bshare-peer-config-') as temp:
            directory = Path(temp)
            fixture, binary = directory / 'fixture.cpp', directory / 'fixture.exe'
            fixture.write_text(source)
            arguments = ['/nologo', '/std:c++17', '/W4', '/WX', '/wd4100', '/EHsc', '/DWIN32', '/DLIB_WEBRTC_API_DLL',
                f'/I{sdk / "include"}',
                f'/I{flutter_root / "bin/cache/artifacts/engine/windows-x64/cpp_client_wrapper/include"}',
                str(fixture), f'/Fo{directory / "fixture.obj"}', f'/Fe{binary}', '/link', str(sdk / 'lib/libwebrtc.dll.lib')]
            compiler = shutil.which('cl')
            if compiler:
                command = [compiler, *arguments]
            else:
                vswhere = Path(os.environ.get('ProgramFiles(x86)', '')) / 'Microsoft Visual Studio/Installer/vswhere.exe'
                installation = subprocess.run([str(vswhere), '-latest', '-products', '*', '-requires',
                    'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'],
                    capture_output=True, text=True, timeout=20, check=True).stdout.strip()
                vcvars = Path(installation) / 'VC/Auxiliary/Build/vcvars64.bat'
                script = directory / 'compile.cmd'
                script.write_text('@echo off\ncall "' + str(vcvars) + '" >nul\n'
                    'if errorlevel 1 exit /b %errorlevel%\ncl ' +
                    ' '.join('"' + value + '"' for value in arguments) + '\nexit /b %errorlevel%\n')
                command = ['cmd', '/c', str(script)]
            compiled = subprocess.run(command, cwd=directory, capture_output=True, text=True, timeout=60)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            environment = dict(os.environ, PATH=str(sdk / 'lib') + os.pathsep + os.environ['PATH'])
            executed = subprocess.run([str(binary)], env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(executed.returncode, 0, executed.stdout + executed.stderr)
            print(executed.stdout.strip())


if __name__ == '__main__': unittest.main()
