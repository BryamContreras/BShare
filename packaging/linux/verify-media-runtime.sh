#!/bin/sh
# Verify actual codec initialization after native package installation. This
# generates only a bounded synthetic clip and never opens a camera/microphone.
set -eu

for component in openh264enc h264parse aacparse mp4mux; do
  gst-inspect-1.0 "$component" >/dev/null
done
audio_encoder=''
for candidate in voaacenc fdkaacenc avenc_aac; do
  if gst-inspect-1.0 "$candidate" >/dev/null 2>&1; then
    audio_encoder="$candidate"
    break
  fi
done
if [ -z "$audio_encoder" ]; then
  echo 'No supported GStreamer AAC encoder is installed.' >&2
  exit 1
fi

media_directory="$(mktemp -d "${TMPDIR:-/tmp}/bshare-codec-check-XXXXXX")"
trap 'rm -f "$media_directory/synthetic.mp4"; rmdir "$media_directory"' EXIT HUP INT TERM
gst-launch-1.0 -q -e \
  mp4mux name=mux faststart=true ! filesink location="$media_directory/synthetic.mp4" \
  videotestsrc num-buffers=12 ! video/x-raw,format=I420,width=160,height=120,framerate=12/1 \
    ! openh264enc bitrate=300000 ! h264parse ! queue ! mux. \
  audiotestsrc wave=silence num-buffers=48 samplesperbuffer=1000 \
    ! audio/x-raw,rate=48000,channels=2 ! audioconvert \
    ! "$audio_encoder" bitrate=128000 ! aacparse ! queue ! mux.
test -s "$media_directory/synthetic.mp4"
gst-launch-1.0 -q \
  filesrc location="$media_directory/synthetic.mp4" ! qtdemux name=demux \
  demux.video_0 ! queue ! h264parse ! openh264dec ! videoconvert ! fakesink sync=false \
  demux.audio_0 ! queue ! decodebin ! audioconvert ! fakesink sync=false
printf 'Installed H.264/AAC MP4 recording components passed (%s).\n' "$audio_encoder"
