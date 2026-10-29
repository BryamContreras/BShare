#ifndef RUNNER_ROUTE_METRIC_POLICY_H_
#define RUNNER_ROUTE_METRIC_POLICY_H_

#include <algorithm>
#include <cstdint>
#include <vector>

namespace bshare {

struct InterfaceRoutePriority {
  bool has_default_route;
  uint64_t metric;
};

inline InterfaceRoutePriority ResolveIpv4RoutePriority(
    uint32_t interface_metric,
    const std::vector<uint32_t>& default_route_metrics,
    bool route_table_available,
    bool has_gateway) {
  if (!route_table_available) return {has_gateway, interface_metric};
  if (default_route_metrics.empty()) return {false, interface_metric};
  const uint32_t route_metric = *std::min_element(default_route_metrics.begin(),
                                                 default_route_metrics.end());
  return {true, static_cast<uint64_t>(interface_metric) + route_metric};
}

}  // namespace bshare

#endif  // RUNNER_ROUTE_METRIC_POLICY_H_
