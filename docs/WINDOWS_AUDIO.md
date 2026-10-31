# Windows receiver audio

BShare receives camera and screen streams as media. Its Windows receiver selects
the current Windows multimedia output by endpoint ID, matching the SDK's device
IDs rather than choosing the first enumerated output. An explicit output selected
through the application remains selected until that device is removed.

The pinned WebRTC SDK initializes its audio engine lazily on the first peer and
resets its output to the communications role during that initialization. BShare
therefore reapplies its media output after creating the first peer, before SDP
negotiation can start playback. A blocking SDK device query fences the queued
selection. Additional active peers reuse the established output; they do not
restart playback. Endpoint notifications follow changes to the default multimedia
output while preserving an explicit selection.

This changes only BShare's output choice. It does not change Windows Communications
preferences, endpoint roles, application volumes, or other applications' sessions.
Receiving media does not require capturing the PC microphone.

## Reproducing the duck-notification check

Build tools: Windows, Python 3, and Visual Studio C++ tools with the Windows SDK.
The optional observer opens its own silent media output, registers duck
notifications for that session, and writes JSON counts. It does not record media.

```powershell
python tool/windows_audio_duck_probe.py --seconds 8 --self-test
python tool/windows_audio_duck_probe.py --seconds 30
```

The first command opens a separate, owned communications process briefly. On the
tested PC it produced one duck and one unduck notification, establishing that the
observer detects Windows ducking. Start a camera or screen receiver during the
second command. Close that receiver before the observer finishes. Run the test
with other communications applications idle so that their streams do not
contaminate the measurement.

For the pinned legacy SDK path, the optional `--calibration legacy-comms` and
`--calibration legacy-explicit` modes compare default communications endpoint
activation with selection of the explicit multimedia endpoint. The former
produced ducking on the tested PC; the latter did not. These modes create and
close only their own silent streams.

`SetDuckingPreference(TRUE)` protects a session from attenuation. It does not
prevent that session from attenuating other applications; the probe's
`--self-test-opt-out` calibration confirms that distinction on the tested PC.
The SDK does not expose the underlying `IAudioClient`, which would be needed to
use `IAudioClientDuckingControl` directly.

The native regression test compiles the production router with isolated SDK and
COM endpoint doubles. It also checks the real OS output when one exists. Its
endpoint matching, first-peer reset and explicit-selection cases run without a
sound card. Run it after a Windows build has downloaded the SDK headers:

```powershell
python test/native/test_windows_media_audio_routing.py
```

The physical S22/Windows comparison and microphone toggle results are recorded in
[windows-audio-ducking-review.json](performance/windows-audio-ducking-review.json).
These results establish the behavior on that PC, rather than every Windows audio
driver or application configuration.

## Primary references

- [WebRTC m144 connection context: lazy media-engine initialization](https://github.com/webrtc-sdk/webrtc/blob/m144_release/pc/connection_context.cc)
- [WebRTC m144 audio-device initialization](https://github.com/webrtc-sdk/webrtc/blob/m144_release/media/engine/adm_helpers.cc)
- [WebRTC m144 Windows Core Audio device selection](https://github.com/webrtc-sdk/webrtc/blob/m144_release/modules/audio_device/win/audio_device_core_win.cc)
- [Microsoft: IAudioSessionControl2.SetDuckingPreference](https://learn.microsoft.com/en-us/windows/win32/api/audiopolicy/nf-audiopolicy-iaudiosessioncontrol2-setduckingpreference)
- [Microsoft: IAudioClientDuckingControl](https://learn.microsoft.com/en-us/windows/win32/api/audioclient/nn-audioclient-iaudioclientduckingcontrol)
