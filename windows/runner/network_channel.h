#ifndef RUNNER_NETWORK_CHANNEL_H_
#define RUNNER_NETWORK_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <memory>

// Exposes Windows adapter routing metadata without changing network settings.
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateNetworkChannel(flutter::BinaryMessenger* messenger);

#endif  // RUNNER_NETWORK_CHANNEL_H_
