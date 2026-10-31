#include "v4l2_output.h"
#include <csignal>
#include <dlfcn.h>
#include <iostream>
#include <regex>
#include <sstream>
#include <sys/wait.h>

using namespace bshare::virtual_camera;
namespace {
std::atomic<CameraDaemon*> running{nullptr};
void Stop(int) { if (auto* daemon = running.load()) daemon->Stop(); }

bool ActiveGraphicalUser() {
  using Sessions = int(*)(uid_t, int, char***);
  using Type = int(*)(const char*, char**);
  static void* library = dlopen("libsystemd.so.0", RTLD_NOW | RTLD_LOCAL);
  static auto sessions = library ? reinterpret_cast<Sessions>(dlsym(library, "sd_uid_get_sessions")) : nullptr;
  static auto type = library ? reinterpret_cast<Type>(dlsym(library, "sd_session_get_type")) : nullptr;
  if (!sessions || !type) return false;
  char** list = nullptr;
  const int count = sessions(geteuid(), 1, &list);
  bool active = false;
  if (count >= 0 && list) {
    for (int index = 0; list[index]; ++index) {
      char* value = nullptr;
      if (type(list[index], &value) >= 0 && value && (!strcmp(value, "x11") || !strcmp(value, "wayland"))) active = true;
      free(value); free(list[index]);
    }
    free(list);
  }
  return active;
}

std::string ReadStatus() {
  const auto directory = RuntimeDirectory(false);
  if (directory.empty()) return {};
  const auto path = directory + "/status.json";
  struct stat info{};
  if (lstat(path.c_str(), &info) || !S_ISREG(info.st_mode) || info.st_uid != geteuid() ||
      (info.st_mode & 0077) || info.st_size > 1024) return {};
  std::ifstream input(path);
  std::string value((std::istreambuf_iterator<char>(input)), {});
  std::smatch match;
  if (!std::regex_search(value, match, std::regex("\"heartbeat\":([0-9]+)"))) return {};
  uint64_t heartbeat = 0;
  try { heartbeat = std::stoull(match[1]); } catch (...) { return {}; }
  const auto now = MonotonicMilliseconds();
  if (heartbeat > now + 100 || now > heartbeat + 3000) return {};
  return value;
}

std::string SetupError() {
  const char* path = "/var/lib/bshare/virtual-camera-status.json";
  struct stat info{};
  if (lstat(path, &info) || !S_ISREG(info.st_mode) || info.st_uid != 0 || info.st_size > 2048) return {};
  std::ifstream input(path);
  std::string value((std::istreambuf_iterator<char>(input)), {});
  std::smatch match;
  if (std::regex_search(value, match, std::regex("\"reason\"\\s*:\\s*\"([a-z-]+)\""))) return match[1];
  return {};
}

void StartUserService() {
  // Start only the installed BShare user unit. Never restart a live producer,
  // request root privileges, or execute an arbitrary shell command.
  const pid_t child = fork();
  if (child == 0) {
    execl("/usr/bin/systemctl", "systemctl", "--user", "--no-block", "start",
          "bshare-virtual-camera.service", static_cast<char*>(nullptr));
    _exit(127);
  }
  if (child < 0) return;
  for (int attempt = 0; attempt < 40; ++attempt) {
    int status = 0;
    if (waitpid(child, &status, WNOHANG) == child) return;
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }
  kill(child, SIGTERM); waitpid(child, nullptr, 0);
}
}

int main(int argc, char** argv) {
  if (argc == 2 && !strcmp(argv[1], "--serve")) {
    V4l2Sink sink;
    CameraDaemon daemon(sink, ActiveGraphicalUser);
    running = &daemon;
    signal(SIGINT, Stop); signal(SIGTERM, Stop);
    const bool result = daemon.Run();
    running = nullptr;
    return result ? 0 : 1;
  }
  if (argc == 3 && !strcmp(argv[1], "--inspect-device")) {
    const std::string path = argv[2];
    if (!std::regex_match(path, std::regex("/dev/video[0-9]{1,3}"))) return 2;
    VideoOperations operations;
    int fd = open(path.c_str(), O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    const bool owned = fd >= 0 && OwnedDevice(fd, operations);
    if (fd >= 0) close(fd);
    std::cout << "{\"owned\":" << (owned ? "true" : "false") << "}\n";
    return owned ? 0 : 2;
  }
  const bool install = argc == 2 && !strcmp(argv[1], "--install");
  if (argc != 2 || (!install && strcmp(argv[1], "--status"))) return 2;
  if (install) StartUserService();
  std::string status = ReadStatus();
  for (int count = 0; install && count < 20 && status.find("\"ready\":true") == std::string::npos; ++count) {
    std::this_thread::sleep_for(std::chrono::milliseconds(50)); status = ReadStatus();
  }
  const bool ready = status.find("\"ready\":true") != std::string::npos;
  const bool producer = status.find("\"producerActive\":true") != std::string::npos;
  const bool component = access("/usr/lib/systemd/user/bshare-virtual-camera.service", R_OK) == 0;
  std::string error = ready ? "" : (FindDevice().empty() ? "kernel-device-unavailable" : "user-service-unavailable");
  if (!ready && FindDevice().empty()) {
    const auto reason = SetupError();
    if (!reason.empty()) error = reason;
  }
  std::cout << "{\"supported\":true,\"sourceRegistered\":" << (component ? "true" : "false")
            << ",\"registered\":" << (ready ? "true" : "false")
            << ",\"producerActive\":" << (producer ? "true" : "false")
            << ",\"deviceName\":\"" << kDeviceName << "\",\"error\":\"" << error << "\"}\n";
  return 0;
}
