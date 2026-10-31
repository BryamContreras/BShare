#ifndef FLUTTER_WEBRTC_MEDIA_AUDIO_ROUTING_POLICY_H_
#define FLUTTER_WEBRTC_MEDIA_AUDIO_ROUTING_POLICY_H_
#include <cctype>
#include <optional>
#include <string>
#include <vector>

namespace flutter_webrtc_plugin {
inline bool SameAudioEndpointId(const std::string& left,
                                const std::string& right) {
  if (left.empty() || left.size() != right.size()) return false;
  for (size_t i = 0; i < left.size(); ++i) {
    if (std::tolower(static_cast<unsigned char>(left[i])) !=
        std::tolower(static_cast<unsigned char>(right[i]))) return false;
  }
  return true;
}

// Labels and enumeration order are not routing identities. In particular, never
// select index zero merely because it exists (it may be a virtual output).
inline std::optional<size_t> FindMediaAudioOutputIndex(
    const std::string& default_media_id,
    const std::vector<std::string>& sdk_output_ids) {
  for (size_t i = 0; i < sdk_output_ids.size(); ++i) {
    if (SameAudioEndpointId(default_media_id, sdk_output_ids[i])) return i;
  }
  return std::nullopt;
}
}  // namespace flutter_webrtc_plugin
#endif
