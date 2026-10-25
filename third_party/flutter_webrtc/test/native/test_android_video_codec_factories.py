#!/usr/bin/env python3
"""Compile the production Android factories against controlled codec catalogs.

Checks SDP capability/creation consistency and preserves H264 levels and formats.
The catalog doubles model software vs hardware support, not actual decoding.
"""

from pathlib import Path
import subprocess
import tempfile


STUBS = {
    "androidx/annotation/Nullable.java": """
package androidx.annotation; public @interface Nullable {}
""",
    "org/webrtc/EglBase.java": """
package org.webrtc; public class EglBase { public interface Context {} }
""",
    "org/webrtc/VideoCodecInfo.java": """
package org.webrtc;
import java.util.*;
public class VideoCodecInfo {
  public final String name;
  public final Map<String,String> params;
  public final List<String> scalabilityModes;
  public VideoCodecInfo(String n,Map<String,String> p,List<String> modes) {
    name=n;params=p;scalabilityModes=modes;
  }
  public boolean equals(Object other) {
    if(!(other instanceof VideoCodecInfo)) return false;
    VideoCodecInfo c=(VideoCodecInfo)other;
    return name.equalsIgnoreCase(c.name)&&params.equals(c.params);
  }
  public int hashCode(){return Objects.hash(name.toUpperCase(Locale.ROOT),params);}
}
""",
    "org/webrtc/Catalog.java": """
package org.webrtc;
import java.util.*;
public class Catalog {
  static VideoCodecInfo codec(String name,String key,String value) {
    return new VideoCodecInfo(name, key.isEmpty()?Map.of():Map.of(key,value), List.of());
  }
  public static final VideoCodecInfo VP8=codec("VP8","","");
  public static final VideoCodecInfo VP9=codec("VP9","profile-id","0");
  public static final VideoCodecInfo VP9_HW=codec("VP9","profile-id","2");
  public static final VideoCodecInfo H264=codec("H264","profile-level-id","42e01f");
  public static final VideoCodecInfo H264_HIGH=codec("H264","profile-level-id","640c2a");
  public static final VideoCodecInfo H264_VENDOR=codec("H264","profile-level-id","vendor");
  public static final VideoCodecInfo[] SOFTWARE={VP8,VP9};
  public static final VideoCodecInfo[] DEFAULT={VP8,VP9,VP9_HW,H264,H264_HIGH,H264_VENDOR};
}
""",
}

for media in ("Encoder", "Decoder"):
    STUBS[f"org/webrtc/Video{media}.java"] = f"""
package org.webrtc;
public class Video{media} {{
  public final boolean software;
  Video{media}(boolean value){{software=value;}}
}}
"""
    STUBS[f"org/webrtc/Video{media}Factory.java"] = f"""
package org.webrtc;
public interface Video{media}Factory {{
  Video{media} create{media}(VideoCodecInfo codec);
  VideoCodecInfo[] getSupportedCodecs();
}}
"""
    STUBS[f"org/webrtc/SoftwareVideo{media}Factory.java"] = f"""
package org.webrtc;
public class SoftwareVideo{media}Factory implements Video{media}Factory {{
  public Video{media} create{media}(VideoCodecInfo codec) {{
    return java.util.Arrays.asList(Catalog.SOFTWARE).contains(codec)?new Video{media}(true):null;
  }}
  public VideoCodecInfo[] getSupportedCodecs(){{return Catalog.SOFTWARE;}}
}}
"""

STUBS["org/webrtc/WrappedVideoDecoderFactory.java"] = """
package org.webrtc;
public class WrappedVideoDecoderFactory implements VideoDecoderFactory {
  public WrappedVideoDecoderFactory(EglBase.Context context){}
  public VideoDecoder createDecoder(VideoCodecInfo codec){return new VideoDecoder(false);}
  public VideoCodecInfo[] getSupportedCodecs(){return Catalog.DEFAULT;}
}
"""
STUBS["com/cloudwebrtc/webrtc/SimulcastVideoEncoderFactoryWrapper.java"] = """
package com.cloudwebrtc.webrtc;
import org.webrtc.*;
public class SimulcastVideoEncoderFactoryWrapper implements VideoEncoderFactory {
  public SimulcastVideoEncoderFactoryWrapper(EglBase.Context context,boolean vp8,boolean h264){}
  public VideoEncoder createEncoder(VideoCodecInfo codec){
    return new SoftwareVideoEncoderFactory().createEncoder(Catalog.VP8);
  }
  public VideoCodecInfo[] getSupportedCodecs(){return Catalog.DEFAULT;}
}
"""

HARNESS = r"""
import java.util.*;
import org.webrtc.*;
import org.webrtc.video.*;
public class AndroidVideoCodecFactoryTest {
  static int checks;
  static void check(boolean ok,String message){checks++;if(!ok)throw new AssertionError(message);}
  static void same(VideoCodecInfo[] actual,VideoCodecInfo... expected){
    check(Arrays.equals(actual,expected),"unexpected advertised formats");
  }
  public static void main(String[] args){
    CustomVideoDecoderFactory decoder=new CustomVideoDecoderFactory(null);
    CustomVideoEncoderFactory encoder=new CustomVideoEncoderFactory(null,true,true);
    same(decoder.getSupportedCodecs(),Catalog.DEFAULT);
    check(decoder.getSupportedCodecs()[3]==Catalog.H264,"must preserve baseline level 3.1");
    check(decoder.getSupportedCodecs()[4]==Catalog.H264_HIGH,"must preserve advertised level 4.2");
    check(decoder.getSupportedCodecs()[5]==Catalog.H264_VENDOR,"do not parse or rewrite vendor fmtp");
    same(encoder.getSupportedCodecs(),Catalog.DEFAULT);
    for(String name:List.of("VP9","vp9")){
      decoder.setForceSWCodecList(List.of(name));encoder.setForceSWCodecList(List.of(name));
      same(decoder.getSupportedCodecs(),Catalog.VP8,Catalog.VP9,Catalog.H264,Catalog.H264_HIGH,Catalog.H264_VENDOR);
      same(encoder.getSupportedCodecs(),Catalog.VP8,Catalog.VP9,Catalog.H264,Catalog.H264_HIGH,Catalog.H264_VENDOR);
      check(decoder.createDecoder(Catalog.VP9).software,"VP9 decoder must use software");
      check(encoder.createEncoder(Catalog.VP9)!=null,"VP9 encoder must exist");
      check(decoder.createDecoder(Catalog.VP9_HW)==null,"unsupported software VP9 profile must not be created");
      check(encoder.createEncoder(Catalog.VP9_HW)==null,"unsupported software VP9 profile must not be created");
      check(!decoder.createDecoder(Catalog.H264).software,"H264 fallback wrapper must remain enabled");
    }
    decoder.setForceSWCodec(true);encoder.setForceSWCodec(true);
    same(decoder.getSupportedCodecs(),Catalog.SOFTWARE);
    same(encoder.getSupportedCodecs(),Catalog.SOFTWARE);
    for(VideoCodecInfo codec:decoder.getSupportedCodecs())check(decoder.createDecoder(codec)!=null,"advertised decoder must exist");
    for(VideoCodecInfo codec:encoder.getSupportedCodecs())check(encoder.createEncoder(codec)!=null,"advertised encoder must exist");
    check(decoder.createDecoder(Catalog.H264)==null,"forced software cannot create H264");
    check(encoder.createEncoder(Catalog.H264)==null,"forced software cannot create H264");
    decoder.setForceSWCodec(false);encoder.setForceSWCodec(false);
    decoder.setForceSWCodecList(List.of("H264"));encoder.setForceSWCodecList(List.of("H264"));
    same(decoder.getSupportedCodecs(),Catalog.VP8,Catalog.VP9,Catalog.VP9_HW);
    same(encoder.getSupportedCodecs(),Catalog.VP8,Catalog.VP9,Catalog.VP9_HW);
    decoder.setForceSWCodecList(List.of());encoder.setForceSWCodecList(List.of());
    same(decoder.getSupportedCodecs(),Catalog.DEFAULT);same(encoder.getSupportedCodecs(),Catalog.DEFAULT);
    System.out.println("Android video codec factories: "+checks+" checks passed");
  }
}
"""


def main():
    plugin = Path(__file__).resolve().parents[2]
    production = plugin / "android/src/main/java/org/webrtc/video"
    with tempfile.TemporaryDirectory(prefix="bshare-codec-factories-") as directory:
        work = Path(directory)
        for name, source in STUBS.items():
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source, encoding="utf-8")
        (work / "AndroidVideoCodecFactoryTest.java").write_text(HARNESS, encoding="utf-8")
        sources = [str(path) for path in work.rglob("*.java")]
        sources.extend(str(production / name) for name in (
            "CustomVideoEncoderFactory.java", "CustomVideoDecoderFactory.java", "VideoCodecSupport.java"
        ))
        subprocess.run(["javac", "-d", directory, *sources], check=True, timeout=60)
        subprocess.run(["java", "-ea", "-cp", directory, "AndroidVideoCodecFactoryTest"], check=True, timeout=15)


if __name__ == "__main__":
    main()
