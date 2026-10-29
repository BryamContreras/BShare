// Winsock must precede Windows headers to avoid the legacy winsock.h API.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <netioapi.h>

#include "network_channel.h"
#include "lan_interface_policy.h"
#include "route_metric_policy.h"
#include "utils.h"

#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <memory>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

static_assert(IF_TYPE_ETHERNET_CSMACD == bshare::kEthernetInterfaceType);
static_assert(IF_TYPE_IEEE80211 == bshare::kWifiInterfaceType);

using AdapterStorage = std::unique_ptr<void, decltype(&std::free)>;

ULONG ReadAdapters(ULONG family, ULONG flags, AdapterStorage* storage,
                   IP_ADAPTER_ADDRESSES** adapters) {
  // Start with Microsoft's recommended size and retry if adapters change.
  ULONG buffer_size = 15000;
  *adapters = nullptr;
  for (int attempt = 0; attempt < 3; ++attempt) {
    storage->reset(std::malloc(buffer_size));
    if (!*storage) return ERROR_NOT_ENOUGH_MEMORY;
    auto* addresses = static_cast<IP_ADAPTER_ADDRESSES*>(storage->get());
    const ULONG status =
        GetAdaptersAddresses(family, flags, nullptr, addresses, &buffer_size);
    if (status == ERROR_BUFFER_OVERFLOW) continue;
    if (status == ERROR_NO_DATA) return NO_ERROR;
    if (status != NO_ERROR) return status;
    *adapters = addresses;
    return NO_ERROR;
  }
  return ERROR_BUFFER_OVERFLOW;
}

bool IsValidUnicastAddress(const SOCKET_ADDRESS& address) {
  if (address.lpSockaddr == nullptr) return false;
  if (address.lpSockaddr->sa_family == AF_INET &&
      address.iSockaddrLength >= static_cast<int>(sizeof(sockaddr_in))) {
    const auto* ipv4 = reinterpret_cast<const sockaddr_in*>(address.lpSockaddr);
    const uint32_t first_octet = ntohl(ipv4->sin_addr.s_addr) >> 24;
    return first_octet != 0 && first_octet != 127 && first_octet < 224;
  }
  if (address.lpSockaddr->sa_family == AF_INET6 &&
      address.iSockaddrLength >= static_cast<int>(sizeof(sockaddr_in6))) {
    const auto* ipv6 = reinterpret_cast<const sockaddr_in6*>(address.lpSockaddr);
    return !IN6_IS_ADDR_UNSPECIFIED(&ipv6->sin6_addr) &&
           !IN6_IS_ADDR_LOOPBACK(&ipv6->sin6_addr) &&
           !IN6_IS_ADDR_MULTICAST(&ipv6->sin6_addr);
  }
  return false;
}

bool HasGateway(const IP_ADAPTER_ADDRESSES& adapter, int family = AF_UNSPEC) {
  for (auto* gateway = adapter.FirstGatewayAddress; gateway != nullptr;
       gateway = gateway->Next) {
    if (IsValidUnicastAddress(gateway->Address) &&
        (family == AF_UNSPEC ||
         gateway->Address.lpSockaddr->sa_family == family)) {
      return true;
    }
  }
  return false;
}

struct DefaultRouteTable {
  bool available = false;
  std::map<ULONG, std::vector<uint32_t>> metrics;
};

DefaultRouteTable ReadIpv4DefaultRoutes() {
  MIB_IPFORWARD_TABLE2* raw_table = nullptr;
  const ULONG status = GetIpForwardTable2(AF_INET, &raw_table);
  std::unique_ptr<MIB_IPFORWARD_TABLE2, decltype(&FreeMibTable)> table(
      raw_table, &FreeMibTable);
  if (status != NO_ERROR || !table) return {};
  DefaultRouteTable result;
  result.available = true;
  for (ULONG i = 0; i < table->NumEntries; ++i) {
    const auto& route = table->Table[i];
    if (route.DestinationPrefix.Prefix.si_family != AF_INET ||
        route.DestinationPrefix.PrefixLength != 0 ||
        route.InterfaceIndex == 0 || route.Loopback ||
        (route.ValidLifetime == 0 && !route.Immortal)) {
      continue;
    }
    result.metrics[route.InterfaceIndex].push_back(route.Metric);
  }
  return result;
}

struct AdapterDetails {
  const IP_ADAPTER_ADDRESSES* adapter;
  bshare::LanAdapterFacts facts;
};

AdapterDetails DescribeAdapter(const IP_ADAPTER_ADDRESSES* adapter) {
  MIB_IF_ROW2 row{};
  row.InterfaceLuid = adapter->Luid;
  row.InterfaceIndex = adapter->IfIndex;
  const bool has_row = GetIfEntry2(&row) == NO_ERROR;
  const bool hardware =
      has_row && row.InterfaceAndOperStatusFlags.HardwareInterface;
  const ULONG type = has_row ? row.Type : adapter->IfType;
  const bool is_up = adapter->OperStatus == IfOperStatusUp;
  const BYTE* mac = has_row ? row.PhysicalAddress : adapter->PhysicalAddress;
  const ULONG mac_length =
      has_row ? row.PhysicalAddressLength : adapter->PhysicalAddressLength;
  std::vector<BYTE> address;
  if (mac_length > 0 &&
      mac_length <= static_cast<ULONG>(has_row ? IF_MAX_PHYS_ADDRESS_LENGTH
                                               : MAX_ADAPTER_ADDRESS_LENGTH)) {
    address.assign(mac, mac + mac_length);
    if (std::all_of(address.begin(), address.end(),
                    [](BYTE value) { return value == 0; })) {
      address.clear();
    }
  }
  return {adapter, {type, is_up, hardware, std::move(address)}};
}

flutter::EncodableList EncodeAddresses(const IP_ADAPTER_ADDRESSES& adapter,
                                       bool* has_ipv4) {
  flutter::EncodableList encoded;
  for (auto* unicast = adapter.FirstUnicastAddress; unicast != nullptr;
       unicast = unicast->Next) {
    const auto& socket = unicast->Address;
    if (!IsValidUnicastAddress(socket) ||
        unicast->DadState == IpDadStateInvalid ||
        unicast->DadState == IpDadStateDuplicate ||
        unicast->DadState == IpDadStateTentative) {
      continue;
    }
    char text[INET6_ADDRSTRLEN]{};
    const int family = socket.lpSockaddr->sa_family;
    const void* raw = nullptr;
    ULONG scope = 0;
    if (family == AF_INET && unicast->OnLinkPrefixLength <= 32) {
      raw = &reinterpret_cast<const sockaddr_in*>(socket.lpSockaddr)->sin_addr;
      *has_ipv4 = true;
    } else if (family == AF_INET6 && unicast->OnLinkPrefixLength <= 128) {
      const auto* ipv6 = reinterpret_cast<const sockaddr_in6*>(socket.lpSockaddr);
      raw = &ipv6->sin6_addr;
      scope = ipv6->sin6_scope_id;
    }
    if (raw == nullptr || InetNtopA(family, raw, text, sizeof(text)) == nullptr) {
      continue;
    }
    std::string ip(text);
    if (scope != 0) ip += "%" + std::to_string(scope);
    encoded.emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("ip"), flutter::EncodableValue(ip)},
        {flutter::EncodableValue("prefixLength"),
         flutter::EncodableValue(static_cast<int32_t>(unicast->OnLinkPrefixLength))},
    });
  }
  return encoded;
}

ULONG GetLanInterfaces(flutter::EncodableList* encoded) {
  AdapterStorage storage(nullptr, &std::free);
  IP_ADAPTER_ADDRESSES* adapters = nullptr;
  constexpr ULONG flags = GAA_FLAG_INCLUDE_ALL_INTERFACES |
                          GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_ANYCAST |
                          GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
  const ULONG status = ReadAdapters(AF_UNSPEC, flags, &storage, &adapters);
  if (status != NO_ERROR) return status;
  const auto routes = ReadIpv4DefaultRoutes();
  const std::vector<uint32_t> no_route_metrics;
  std::vector<AdapterDetails> details;
  std::vector<bshare::LanAdapterFacts> facts;
  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    details.push_back(DescribeAdapter(adapter));
    facts.push_back(details.back().facts);
  }
  for (const auto& detail : details) {
    const auto& adapter = *detail.adapter;
    const ULONG index = adapter.IfIndex != 0 ? adapter.IfIndex : adapter.Ipv6IfIndex;
    if (index == 0) continue;
    bool has_ipv4 = false;
    auto addresses = EncodeAddresses(adapter, &has_ipv4);
    bshare::InterfaceRoutePriority priority{
        HasGateway(adapter, AF_INET6), adapter.Ipv6Metric};
    if (has_ipv4) {
      const auto route = routes.metrics.find(index);
      // Windows ranks default routes by route cost plus interface cost.
      // Gateway presence is only a fallback when the route table is unavailable.
      priority = bshare::ResolveIpv4RoutePriority(
          adapter.Ipv4Metric,
          route == routes.metrics.end() ? no_route_metrics : route->second,
          routes.available, HasGateway(adapter, AF_INET));
    }
    const auto classification =
        bshare::ClassifyLanInterface(detail.facts, facts, !addresses.empty());
    const char* kind = classification.is_bridge ? "bridge"
        : detail.facts.type == IF_TYPE_IEEE80211 ? "wifi"
        : detail.facts.type == IF_TYPE_ETHERNET_CSMACD ? "ethernet" : "other";
    const std::string name = adapter.FriendlyName != nullptr
        ? Utf8FromUtf16(adapter.FriendlyName)
        : adapter.AdapterName != nullptr ? adapter.AdapterName : "";
    encoded->emplace_back(flutter::EncodableMap{
        {flutter::EncodableValue("index"),
         flutter::EncodableValue(static_cast<int64_t>(index))},
        {flutter::EncodableValue("name"), flutter::EncodableValue(name)},
        {flutter::EncodableValue("addresses"),
         flutter::EncodableValue(std::move(addresses))},
        {flutter::EncodableValue("kind"), flutter::EncodableValue(kind)},
        {flutter::EncodableValue("isUp"),
         flutter::EncodableValue(detail.facts.is_up)},
        {flutter::EncodableValue("isLan"),
         flutter::EncodableValue(classification.is_lan)},
        {flutter::EncodableValue("hasDefaultRoute"),
         flutter::EncodableValue(priority.has_default_route)},
        {flutter::EncodableValue("metric"), flutter::EncodableValue(
            static_cast<int64_t>(priority.metric))},
    });
  }
  return NO_ERROR;
}

ULONG GetRoutedInterfaceIndexes(flutter::EncodableList* encoded) {
  AdapterStorage storage(nullptr, &std::free);
  IP_ADAPTER_ADDRESSES* adapters = nullptr;
  constexpr ULONG flags = GAA_FLAG_INCLUDE_GATEWAYS | GAA_FLAG_SKIP_UNICAST |
                          GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                          GAA_FLAG_SKIP_DNS_SERVER;
  const ULONG status = ReadAdapters(AF_INET, flags, &storage, &adapters);
  if (status != NO_ERROR) return status;
  for (auto* adapter = adapters; adapter != nullptr; adapter = adapter->Next) {
    if (adapter->OperStatus == IfOperStatusUp && adapter->IfIndex != 0 &&
        adapter->IfType != IF_TYPE_SOFTWARE_LOOPBACK &&
        adapter->IfType != IF_TYPE_TUNNEL && HasGateway(*adapter, AF_INET)) {
      encoded->emplace_back(static_cast<int64_t>(adapter->IfIndex));
    }
  }
  return NO_ERROR;
}

}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateNetworkChannel(flutter::BinaryMessenger* messenger) {
  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "bshare/network",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        flutter::EncodableList encoded;
        ULONG status = NO_ERROR;
        if (call.method_name() == "getLanInterfaces") {
          status = GetLanInterfaces(&encoded);
        } else if (call.method_name() == "getRoutedInterfaceIndexes") {
          status = GetRoutedInterfaceIndexes(&encoded);
        } else {
          result->NotImplemented();
          return;
        }
        if (status != NO_ERROR) {
          result->Error(
              "network_interfaces_unavailable",
              "Windows could not enumerate network interfaces.",
              flutter::EncodableValue(static_cast<int64_t>(status)));
          return;
        }
        result->Success(flutter::EncodableValue(std::move(encoded)));
      });
  return channel;
}
