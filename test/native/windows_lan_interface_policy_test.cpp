#include "windows/runner/lan_interface_policy.h"

#include <iostream>
#include <vector>

namespace {

using bshare::LanAdapterFacts;
using bshare::LanInterfaceClassification;

struct Fixture {
  const char* description;
  LanAdapterFacts adapter;
  std::vector<LanAdapterFacts> uplinks;
  bool has_address;
  LanInterfaceClassification expected;
};

}  // namespace

int main() {
  const std::vector<uint8_t> physical_mac{0x02, 0x11, 0x22, 0x33, 0x44, 0x55};
  const std::vector<uint8_t> software_mac{0x02, 0x99, 0x88, 0x77, 0x66, 0x55};
  const LanAdapterFacts ethernet{6, true, true, physical_mac};
  const LanAdapterFacts wifi{71, true, true, physical_mac};
  const LanAdapterFacts down_ethernet{6, false, true, physical_mac};

  // Friendly names and gateways are intentionally absent from the production
  // classifier's input. Neither a renamed adapter nor a VPN's default route can
  // establish physical eligibility. These fixtures describe those OS contexts.
  const std::vector<Fixture> fixtures{
      {"hardware Ethernet, no default gateway", ethernet, {}, true, {true, false}},
      {"hardware Wi-Fi, local-only network", wifi, {}, true, {true, false}},
      {"hardware NIC renamed to WSL", ethernet, {}, true, {true, false}},
      {"hardware NIC renamed to TAP-WireGuard", wifi, {}, true, {true, false}},
      {"external bridge, no gateway, uplink shares MAC",
       {6, true, false, physical_mac}, {ethernet}, true, {true, true}},
      {"external bridge with arbitrary label, Wi-Fi uplink",
       {6, true, false, physical_mac}, {wifi}, true, {true, true}},
      {"TAP Ethernet VPN with default gateway",
       {6, true, false, software_mac}, {ethernet}, true, {false, false}},
      {"Wintun VPN with default gateway",
       {53, true, false, software_mac}, {ethernet}, true, {false, false}},
      {"WireGuard VPN with default gateway",
       {131, true, false, software_mac}, {ethernet}, true, {false, false}},
      {"VPN reporting Ethernet type, friendly label Office LAN",
       {6, true, false, software_mac}, {ethernet}, true, {false, false}},
      {"internal WSL interface without physical uplink",
       {6, true, false, software_mac}, {}, true, {false, false}},
      {"host-only interface named Ethernet",
       {6, true, false, software_mac}, {ethernet}, true, {false, false}},
      {"unknown virtual guest NIC with default gateway",
       {6, true, false, software_mac}, {}, true, {false, false}},
      {"guest NIC reported by Windows as hardware",
       {6, true, true, software_mac}, {}, true, {true, false}},
      {"hardware Ethernet with no assigned address",
       ethernet, {}, false, {false, false}},
      {"unplugged hardware Ethernet retaining an address",
       down_ethernet, {}, true, {false, false}},
      {"bridge uplink is down",
       {6, true, false, physical_mac}, {down_ethernet}, true, {false, false}},
      {"bridge has no assigned address",
       {6, true, false, physical_mac}, {ethernet}, false, {false, true}},
      {"down bridge retains an address",
       {6, false, false, physical_mac}, {ethernet}, true, {false, true}},
      {"missing MAC cannot establish a bridge",
       {6, true, false, {}}, {{6, true, true, {}}}, true, {false, false}},
      {"zero MAC cannot establish a bridge",
       {6, true, false, {0, 0, 0, 0, 0, 0}},
       {{6, true, true, {0, 0, 0, 0, 0, 0}}}, true, {false, false}},
      {"tunnel sharing a physical MAC stays excluded",
       {131, true, false, physical_mac}, {ethernet}, true, {false, false}},
      {"loopback reporting hardware stays excluded",
       {24, true, true, physical_mac}, {ethernet}, true, {false, false}},
      {"PPP reporting hardware stays excluded",
       {23, true, true, physical_mac}, {ethernet}, true, {false, false}},
  };
  int failures = 0;
  for (const auto& fixture : fixtures) {
    const auto actual = bshare::ClassifyLanInterface(
        fixture.adapter, fixture.uplinks, fixture.has_address);
    if (actual.is_lan != fixture.expected.is_lan ||
        actual.is_bridge != fixture.expected.is_bridge) {
      std::cerr << "FAILED: " << fixture.description << " (lan="
                << actual.is_lan << ", bridge=" << actual.is_bridge << ")\n";
      ++failures;
    }
  }
  if (failures != 0) return 1;
  std::cout << fixtures.size() << " native LAN classification fixtures passed\n";
  return 0;
}
