#ifndef RUNNER_LAN_INTERFACE_POLICY_H_
#define RUNNER_LAN_INTERFACE_POLICY_H_

#include <algorithm>
#include <cstdint>
#include <vector>

namespace bshare {

// IANA interface types reported by GetIfEntry2/GetAdaptersAddresses.
constexpr uint32_t kEthernetInterfaceType = 6;
constexpr uint32_t kWifiInterfaceType = 71;

struct LanAdapterFacts {
  uint32_t type;
  bool is_up;
  bool is_hardware;
  std::vector<uint8_t> mac;
};

struct LanInterfaceClassification {
  bool is_lan;
  bool is_bridge;
};

inline bool IsLanHardwareType(uint32_t type) {
  return type == kEthernetInterfaceType || type == kWifiInterfaceType;
}

// Labels and default routes do not establish a physical LAN connection. Keep
// those metadata fields outside the classifier so a VPN gateway cannot make a
// software Ethernet adapter eligible. A guest NIC reported as hardware is valid.
inline LanInterfaceClassification ClassifyLanInterface(
    const LanAdapterFacts& adapter,
    const std::vector<LanAdapterFacts>& interfaces,
    bool has_usable_address) {
  const bool has_mac = std::any_of(adapter.mac.begin(), adapter.mac.end(),
                                   [](uint8_t value) { return value != 0; });
  const bool shares_uplink = !adapter.is_hardware && has_mac &&
      IsLanHardwareType(adapter.type) &&
      std::any_of(interfaces.begin(), interfaces.end(), [&](const auto& uplink) {
        return uplink.is_up && uplink.is_hardware &&
               IsLanHardwareType(uplink.type) && uplink.mac == adapter.mac;
      });
  return {
      adapter.is_up && has_usable_address &&
          ((adapter.is_hardware && IsLanHardwareType(adapter.type)) ||
           shares_uplink),
      shares_uplink,
  };
}

}  // namespace bshare

#endif  // RUNNER_LAN_INTERFACE_POLICY_H_
