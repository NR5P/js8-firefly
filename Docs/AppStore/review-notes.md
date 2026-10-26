# App Review information: JS8 Firefly 1.0

Fill these in under App Store Connect → Distribution → iOS App 1.0 → App Review Information.

- **Sign-in required:** No
- **Contact:** Nathan Rigg · nathan@nr5p.com · (your phone number)
- **Attachment:** none for now. The notes offer a video of a real on-air contact if App Review asks.

## Notes (paste into the Notes box, 4000 characters max)

```
JS8 Firefly is an amateur (ham) radio app. It sends and receives JS8, a weak-signal digital text mode, through an HF radio connected to the iPhone or iPad with a USB-C audio interface (for example a Digirig Lite or a QRP Labs QMX radio). It is compatible with the JS8Call desktop program. No account or sign-in is needed.

HOW TO REVIEW WITHOUT A RADIO
1. Launch the app. On the welcome screen tap "Just listen for now" (or enter any callsign such as N0CALL and grid EM12).
2. Allow microphone access. Without a radio interface, the built-in microphone is used as the receive input.
3. The Live tab shows a scrolling waterfall of the received audio and the band activity list. The ring at the top left counts down each 15-second transmit period.
4. To see decoding, play a JS8 recording (there are many online) near the device. Decoded messages appear on the waterfall, in Band Activity, in the Chat tab, and in the Stations tab. We are happy to provide a video of the app making a real on-air contact on request.
5. The band picker (tap the frequency at the top right) shows standard JS8 calling frequencies. "My frequencies" lets users save their own labeled frequencies.

Transmitting (CQ, HB and the message box) needs a licensed operator and a radio connected through an audio interface. Without one, a transmission only plays audio tones from the speaker.

PERMISSIONS
- Microphone: receive audio from the radio interface for decoding. Audio is processed on device and never recorded or uploaded.
- Bluetooth: optional, connects to a Bluetooth LE serial (CAT) adapter that tunes the radio.
- Local network: optional, controls the radio through a rigctld or flrig server on the user's own network.
- Notifications: local alerts when a message is addressed to the user.

BACKGROUND AUDIO
The app declares the "audio" background mode because operators leave it running in the background to keep receiving and decoding the radio, like a scanner. While in the background it keeps capturing audio from the radio interface, decoding JS8 messages, and sending automatic replies the user has turned on (standard JS8 behavior). It posts a local notification when a message arrives for the user. The "bluetooth-central" mode keeps the Bluetooth CAT connection to the radio alive during this time.

PRIVACY
The app collects no data and makes no internet connections. Everything stays on the device.

LICENSE
JS8 Firefly is free, open-source software (GNU GPL v3), derived from JS8Call by Jordan Sherer (KN4CRD). Source: https://github.com/NR5P/js8-firefly. Users need an amateur radio license to transmit.
```
