# Google Play Data Safety Notes

Use this as a working guide while completing the Play Console form.

## App Behavior

BShare transfers files directly between nearby devices over LAN or a temporary local Wi-Fi network. It does not use a BShare cloud backend.

## Data Collection

Suggested answer:

- Data collected by developer: No, unless you later add analytics, crash reporting, accounts, or a backend.
- Data shared with developer/third parties: No.
- User-initiated sharing: Yes. Users intentionally select files, apps, media, folders, or screen sharing to send to another nearby device.

## Permissions To Explain

- Camera: scans BShare QR codes.
- Photos/videos/media: lets the user select media to send.
- Storage/all files access: lets the user browse folders and save received files in the selected BShare folder.
- Nearby Wi-Fi/location-related permissions: discover nearby devices and connect to local/direct Wi-Fi networks.
- Notifications/foreground service: keeps screen sharing active and visible while running.

## Security Practices

- Local-only transfer path.
- No BShare cloud upload.
- User chooses what to send.
- Temporary Android share-cache files are deleted after sending, cancelling, or clearing the selected shared files.

## Manual Items

Play Console still requires a public privacy policy URL. Host a policy page before production release and make sure it matches this behavior.
