package org.webrtc.video;

import org.webrtc.VideoCodecInfo;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Keeps SDP capabilities consistent with the factory used to create a codec. */
final class VideoCodecSupport {
    private VideoCodecSupport() {}

    static boolean requiresSoftware(VideoCodecInfo codec, List<String> names) {
        for (String name : names) {
            if (codec.name.equalsIgnoreCase(name)) return true;
        }
        return false;
    }

    static VideoCodecInfo[] filterSoftwareOnlyFormats(
            VideoCodecInfo[] available, VideoCodecInfo[] software, List<String> names) {
        if (names.isEmpty()) return available;
        List<VideoCodecInfo> softwareFormats = Arrays.asList(software);
        List<VideoCodecInfo> supported = new ArrayList<>();
        for (VideoCodecInfo codec : available) {
            // Match the complete format, not just its name: VP9 profile 2,
            // for example, must not be offered when software only has profile 0.
            if (!requiresSoftware(codec, names) || softwareFormats.contains(codec)) {
                supported.add(codec);
            }
        }
        return supported.toArray(new VideoCodecInfo[0]);
    }
}
