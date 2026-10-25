package org.webrtc.video;

import androidx.annotation.Nullable;

import org.webrtc.EglBase;
import org.webrtc.SoftwareVideoDecoderFactory;
import org.webrtc.VideoCodecInfo;
import org.webrtc.VideoDecoder;
import org.webrtc.VideoDecoderFactory;
import org.webrtc.WrappedVideoDecoderFactory;

import java.util.ArrayList;
import java.util.List;

public class CustomVideoDecoderFactory implements VideoDecoderFactory {
    private SoftwareVideoDecoderFactory softwareVideoDecoderFactory = new SoftwareVideoDecoderFactory();
    private WrappedVideoDecoderFactory wrappedVideoDecoderFactory;
    private boolean forceSWCodec  = false;

    private List<String> forceSWCodecs = new ArrayList<>();

    public  CustomVideoDecoderFactory(EglBase.Context sharedContext) {
        this.wrappedVideoDecoderFactory = new WrappedVideoDecoderFactory(sharedContext);
    }

    public void setForceSWCodec(boolean forceSWCodec) {
        this.forceSWCodec = forceSWCodec;
    }

    public void setForceSWCodecList(List<String> forceSWCodecs) {
        this.forceSWCodecs = forceSWCodecs;
    }

    @Nullable
    @Override
    public VideoDecoder createDecoder(VideoCodecInfo videoCodecInfo) {
        if (forceSWCodec || VideoCodecSupport.requiresSoftware(videoCodecInfo, forceSWCodecs)) {
            return softwareVideoDecoderFactory.createDecoder(videoCodecInfo);
        }
        return wrappedVideoDecoderFactory.createDecoder(videoCodecInfo);
    }

    @Override
    public VideoCodecInfo[] getSupportedCodecs() {
        if (forceSWCodec) {
            return softwareVideoDecoderFactory.getSupportedCodecs();
        }
        // Keep the decoder's advertised H.264 profile/level. Raising every
        // device to level 4.1 claims support the selected decoder may lack.
        return VideoCodecSupport.filterSoftwareOnlyFormats(
                wrappedVideoDecoderFactory.getSupportedCodecs(),
                softwareVideoDecoderFactory.getSupportedCodecs(), forceSWCodecs);
    }
}
