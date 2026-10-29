// From a Visual Studio developer shell:
// cl /std:c++17 /EHsc /W4 /WX /I . test/native/windows_route_metric_policy_test.cpp
// Linux/macOS: c++ -std=c++17 -I . test/native/windows_route_metric_policy_test.cpp
#include "windows/runner/route_metric_policy.h"

#include <cstdint>
#include <iostream>
#include <limits>

int main() {
  // Ethernet has a lower interface metric, but Wi-Fi's route has a lower total.
  const auto ethernet = bshare::ResolveIpv4RoutePriority(5, {200}, true, true);
  const auto wifi = bshare::ResolveIpv4RoutePriority(30, {10}, true, true);
  if (!ethernet.has_default_route || !wifi.has_default_route ||
      ethernet.metric != 205 || wifi.metric != 40 ||
      wifi.metric >= ethernet.metric) return 1;

  // Multiple default routes on one NIC use the least expensive live route.
  const auto multiple = bshare::ResolveIpv4RoutePriority(25, {200, 5, 80}, true, true);
  if (!multiple.has_default_route || multiple.metric != 30) return 2;

  // An on-link default route need not have a gateway. A configured gateway
  // without an active route must not become a default route after enumeration.
  const auto on_link = bshare::ResolveIpv4RoutePriority(25, {0}, true, false);
  const auto absent = bshare::ResolveIpv4RoutePriority(25, {}, true, true);
  if (!on_link.has_default_route || on_link.metric != 25 ||
      absent.has_default_route || absent.metric != 25) return 3;

  const auto fallback = bshare::ResolveIpv4RoutePriority(25, {}, false, true);
  const auto local_only = bshare::ResolveIpv4RoutePriority(25, {}, false, false);
  if (!fallback.has_default_route || fallback.metric != 25 ||
      local_only.has_default_route || local_only.metric != 25) return 4;

  const uint32_t maximum = std::numeric_limits<uint32_t>::max();
  const auto large = bshare::ResolveIpv4RoutePriority(maximum, {maximum}, true, true);
  if (large.metric != UINT64_C(8589934590)) return 5;

  std::cout << "Native Windows default-route priority scenarios passed\n";
  return 0;
}
