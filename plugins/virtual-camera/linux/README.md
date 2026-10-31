# Linux virtual camera

BShare's Linux backend uses one named **BShare Virtual Camera** v4l2loopback
device. A per-user daemon keeps its video-output descriptor open and supplies a
1280 × 720, nominal 30 FPS YUYV stream. It displays a waiting image when BShare
is closed, the receiver disconnects, or the publisher stops responding. A
received portrait image is fitted with black bars rather than stretched.

The device uses `exclusive_caps=1`. As described by
[v4l2loopback](https://github.com/v4l2loopback/v4l2loopback#options), attaching a
producer makes the device advertise capture capabilities to ordinary camera
applications. The daemon supplies that producer even without an active broadcast.

## Installer behavior

DEB packages depend on `v4l2loopback-dkms` and `v4l2loopback-utils`, and recommend
the distribution's kernel headers. The package manager builds the driver for
kernels with matching headers. Fedora packages suggest the available
`akmod-v4l2loopback`/`v4l2loopback` packages; BShare never enables RPM Fusion or
another repository automatically.

The installer enables a system setup unit and a user service. With the dynamic
device API (driver and tools version 0.13 or later), setup reuses an already
loaded module; otherwise it first loads zero generic devices, then adds only the
named BShare device. Older versions, including Ubuntu 22.04's 0.12.5 package,
load one named BShare device on the first module load. If an older module is
already serving another camera, setup reports `unsupported-driver-version`
instead of reloading that module. Setup does not
unload the module, replace existing OBS cameras, overwrite global modprobe
options or stop another application. The system unit repeats setup at boot.
Existing active graphical users' BShare service starts during installation;
future graphical sessions start it through the user default target.

The udev rule grants the active local user access to this exact camera label.
The native writer additionally verifies the character-device major, loopback
driver and label before changing formats or writing frames. It releases the
writer when its user no longer has an active graphical session. Only BShare's
device and services are candidates for uninstall cleanup; busy device consumers
are left alone until they close or the system restarts.

Matching headers, a loadable driver and the distribution's normal kernel module
signing/enrolment remain prerequisites. Setup records missing headers, missing
driver tools and rejected signatures in
`/var/lib/bshare/virtual-camera-status.json`. Those conditions do not become a
false successful device registration. Secure Boot keys are not disabled or
enrolled by BShare. See the upstream
[kernel and DKMS guidance](https://github.com/v4l2loopback/v4l2loopback#dkms).

## Frame transport

The application and daemon use a private directory under `$XDG_RUNTIME_DIR`, a
mode-0600 Unix sequenced-packet socket and `SO_PEERCRED` checks for the same UID.
The producer passes a bounded, size-sealed anonymous `memfd` over `SCM_RIGHTS`.
No video is placed in a filesystem file or a network listener.

A robust process-shared mutex protects the latest BGRA frame. The application
callback only queues the newest frame; a worker handles IPC and a 250 ms
heartbeat. Frames older than 1.5 seconds, malformed dimensions and a disconnected
producer return to the waiting image. Static screens remain visible while their
publisher is alive. Concurrent producers cannot replace an active producer.

`bshare-camera --status` reports readiness without opening a capture stream.
`--install` only starts the installed BShare user unit; it neither requests root
privileges nor restarts a running producer. `--serve` is the user-service entry.

## Validation and limits

Local MP4 recording uses OpenH264 and the first installed AAC encoder from
`voaacenc`, `fdkaacenc`, or `avenc_aac`, at 128 kbit/s. The
[Fedora 44 bad-free package](https://packages.fedoraproject.org/pkgs/gstreamer1-plugins-bad-free/gstreamer1-plugins-bad-free/fedora-44.html)
provides `fdkaacenc`; GStreamer negotiates its
[S16LE input](https://gstreamer.freedesktop.org/documentation/fdkaac/fdkaacenc.html)
or libav's [F32LE input](https://gstreamer.freedesktop.org/documentation/libav/avenc_aac.html)
through `audioconvert`. Native checks decode recordings with real `voaacenc`
and `avenc_aac` plugins in isolated registries; the FDK route follows its
documented caps and has not been executed on Fedora here.

The production C++ publisher, daemon and V4L2 ownership code compile under Debian
WSL with `-Wall -Wextra -Werror`. Native checks exercise sealed shared memory,
cross-process recovery after a writer dies, live frames, clear/disconnect idle
continuity, exclusive producers, secure runtime paths and device-ioctl doubles
which reject physical or OBS-labelled cameras. No kernel module was installed
or loaded for those checks. They do not establish real v4l2loopback capture,
kernel/DKMS support or camera-application compatibility on a native Linux host.

```sh
python3 test/native/test_linux_virtual_camera.py
python3 -m unittest discover -s tool -p 'test_linux_virtual_camera_setup.py'
```

Compatibility decisions follow the upstream
[0.12.5 control tool](https://github.com/v4l2loopback/v4l2loopback/blob/v0.12.5/utils/v4l2loopback-ctl),
[0.12.5 module parameters](https://github.com/v4l2loopback/v4l2loopback/blob/v0.12.5/v4l2loopback.c)
and [0.13 dynamic control tool](https://github.com/v4l2loopback/v4l2loopback/blob/v0.13.0/utils/v4l2loopback-ctl.c).

The implementation writes the output interface described in the
[Linux V4L2 API](https://docs.kernel.org/userspace-api/media/v4l/dev-output.html).
The kernel driver remains the distribution's separately licensed v4l2loopback
component; BShare does not embed or replace its source or module binary.
