# USB-C radio interface: design spec

Working name: **Firefly Link**. Status: draft, nothing built yet. Last updated 2026-11-02.

A small bus-powered box with a USB-C cable to the iPhone or iPad and ports for the radio. It gives an iPhone both audio **and CAT** with QRP Labs QMX/QDX, (tr)uSDX, and analog radios, which iOS can't do today because App Store apps can't open USB serial ports.

## 1. Goals

- One USB-C cable to the phone. Powered by the phone, no battery or external supply.
- Audio in both directions as a standard USB sound card, so it works with any app, not only Firefly.
- CAT (frequency, mode, PTT) from an App Store app, without Apple's MFi program.
- Works with:
  - analog radios through Digirig-compatible TRRS cables, plus a CAT jack
  - the (tr)uSDX, through its audio jacks plus its CH340 USB serial, or through its USB alone
  - QMX/QDX and other radios with USB audio and USB serial, such as the IC-7300 and IC-705
- Also works on a Mac and on Android, since everything it uses is a standard USB device.

Non-goals: powering a transmitter, Bluetooth, carrying the radio's DC power.

## 2. The core idea: CAT over USB MIDI

iOS gives App Store apps no access to USB serial devices. It does give every app access to class-compliant **USB MIDI** devices through CoreMIDI, with no MFi certification or entitlement. So the interface presents itself to the phone as a composite USB device:

| Interface | USB class | Carries |
|---|---|---|
| Audio | USB Audio Class 2.0 | Receive and transmit audio, 48 kHz |
| MIDI | USB MIDI 1.0 | CAT bytes, port control and PTT, as SysEx messages |

Firefly unwraps the SysEx and hands the bytes to its existing CAT code. Most USB audio interfaces sold for music are this same audio + MIDI combination, so iOS handles it well.

## 3. Block diagram

```
 iPhone / iPad / Mac / Android
          │ USB-C (device side: 5 V in, Rd 5.1 kΩ on CC1/CC2)
          ▼
 ┌────────────────────────────────────────────────────────┐
 │ ESD + common-mode choke                                  │
 │                                                          │
 │   MCU                                                    │
 │   ├─ USB device: UAC2 audio + USB MIDI (composite)       │
 │   ├─ SysEx ⇄ byte bridge, port router, PTT logic         │
 │   ├─ audio router / resampler                            │
 │   ├─ I2S ──► codec ──► buffers ──► TRRS jack (analog)    │
 │   ├─ UART ─► level select ──► CAT jack (TTL/RS-232/CI-V) │
 │   ├─ GPIO ─► PTT driver (open drain / opto) ──► TRRS+jack│
 │   └─ USB host ─► load switch ─► USB-A/C (radio's USB)    │
 └────────────────────────────────────────────────────────┘
```

## 4. Radio-side ports and setups

| Setup | Audio path | CAT path | PTT | Phase |
|---|---|---|---|---|
| A. Analog radio (FT-891, FT-857, Xiegu G90…) | Codec + TRRS | CAT jack | PTT line, or CAT | 1 |
| B. (tr)uSDX, two cables | Codec + TRRS (Digirig uSDX cable) | USB host to its CH340 | PTT line, or CAT `TX0;` / `RX;` | 2 |
| C. (tr)uSDX, one USB cable | USB host: the box converts its 8-bit serial audio to UAC | Same serial link | CAT | 3 |
| D. QMX/QDX, IC-7300, IC-705… | USB host: the box takes the radio's USB audio and passes it through | USB host to the radio's serial port | CAT | 4 |

Only one host can own a USB device, so in setups C and D the box is the radio's USB host and relays everything to the phone. The phone never talks to the radio directly.

## 5. Phone-side USB device

### 5.1 Descriptors

- Composite device with an interface association descriptor (IAD) for each function.
- **Audio (UAC2):**
  - Stereo, 48 kHz, 16-bit at minimum (24-bit if the MCU can keep up).
  - Asynchronous isochronous endpoints with a feedback endpoint, so the box's clock is the master. This is what lets setup D pass through the radio's audio without drift.
  - Receive audio goes out on the left channel and is duplicated to the right. Transmit audio uses the left channel and ignores the right, so the Digirig Lite "PTT tone" setting does no harm.
  - Feature unit for volume and mute on both directions, so iOS can show input gain. Firefly already reads `isInputGainSettable`.
- **MIDI:** one MIDI IN jack and one MIDI OUT jack, bulk endpoints.
- Product string: `Firefly Link`. Firefly finds the device by this name, and the hello message (6.4) confirms it.
- Prototypes use a hobby VID/PID, such as pid.codes. A product needs its own USB VID/PID.

### 5.2 Power

- The device-side USB-C receptacle has Rd (5.1 kΩ) on both CC pins, so the phone sees a sink and supplies 5 V.
- iPhone 15 and later supply about 4.5 W to accessories. **Design budget: 500 mA total, target under 250 mA without the radio-side USB port.**
- Estimated budget:

| Load | mA (estimate) |
|---|---|
| MCU (RP2350 at 150 MHz, or i.MX RT1062 underclocked) | 30–100 |
| Codec (TLV320AIC3204) | 10–25 |
| Op-amps, level shifters, RS-232 charge pump | 5–15 |
| LEDs (PTT, power, link) | 2–6 |
| Radio-side USB VBUS (current-limited) | 0–300 |

- Radio-side VBUS goes through a current-limited load switch (TPS2553 or AP22652, set to about 300 mA) with fault reporting to the MCU. Most radios power their own USB chip from their DC supply, so the box can leave VBUS off for them. Make it switchable by firmware.
- Soft-start the bulk capacitance (under 10 µF directly on VBUS) so the phone doesn't flag an inrush fault.
- **Measure on real iPhones early.** iOS shows "accessory uses too much power" and cuts the port if the draw is too high.

## 6. CAT over MIDI: SysEx protocol

### 6.1 Framing

```
F0 7D <ver> <port> <cmd> <seq> <payload…> F7
```

- `7D`: the non-commercial manufacturer ID, for prototypes only. A product needs an ID from the MIDI Association, and this field becomes 1 or 3 bytes.
- `ver`: protocol version, starting at `01`.
- `port`: `00` USB host serial, `01` CAT jack, `0F` the box itself.
- `seq`: 7-bit rolling counter, so lost messages can be detected.
- `payload`: 8-bit data packed 7 bits per byte. Each group of 7 data bytes becomes 8 MIDI bytes: the first carries the high bits of the next 7. Overhead is 14%.
- Keep each SysEx message to 256 payload bytes or less, so both ends can use fixed-size buffers.

### 6.2 Commands

| cmd | Direction | Payload | Meaning |
|---|---|---|---|
| `01` | phone → box | bytes | Write to the port |
| `02` | box → phone | bytes | Bytes read from the port. The box flushes after 2 ms idle or 64 bytes |
| `10` | phone → box | baud (u32), data bits, parity, stop bits | Configure the port |
| `11` | phone → box | bit 0 RTS, bit 1 DTR | Set the modem control lines |
| `12` | phone → box | 0/1 | PTT line off/on |
| `13` | phone → box | mode | CAT jack level: TTL 3.3 V, TTL 5 V, RS-232, CI-V |
| `20` | phone → box | none | Hello / status request |
| `21` | box → phone | version, ports, detected radio USB VID/PID and chip type, VBUS fault, PTT state | Status reply. The box also sends it when anything changes |
| `30` | phone → box | mode | Audio source: codec, USB host pass-through, (tr)uSDX stream |
| `7F` | box → phone | code | Error: bad framing, buffer overflow, unsupported command |

### 6.3 Throughput

USB MIDI on full-speed bulk endpoints carries 3 MIDI bytes per 4-byte packet, well over 100 kB/s in practice. CAT at 115200 baud is about 11.5 kB/s, or about 13 kB/s after 7-bit packing, so there's plenty of headroom.

### 6.4 Safety

- **PTT watchdog:** if the box gets no message from the phone for 2 s while PTT is on, it drops PTT and sends `RX;` (or the right command for the protocol) on the CAT port. Firefly sends a keep-alive `20` every 500 ms while transmitting.
- PTT drops whenever the phone disconnects or the USB bus suspends.
- PTT is always off at power-on and after a firmware reset.

## 7. Analog section

- **Codec:** TI TLV320AIC3204. It's low-power, has I2S and an I2C control bus, and has programmable gain on both directions. The SGTL5000 is a fine choice for prototyping on the Teensy audio shield.
- **Transmit (to the radio's mic or data input):** codec line out → attenuator (with jumper options for mic level, about -40 dBV, or line level, about -10 dBV) → DC-blocking capacitor → TRRS.
- **Receive (from the radio's speaker or data output):** TRRS → about 10 kΩ input → AC coupling → codec line in. It should handle speaker-level signals up to about 2 V RMS without clipping.
- **TRRS jack:** copy the published **Digirig audio jack pinout**, so Digirig's ready-made radio cables (including the uSDX cable) plug straight in. *Confirm the pinout against Digirig's documentation before layout.*
- **Optional:** 600:600 Ω isolation transformers on both audio lines (assembly option) to break ground loops.

## 8. CAT jack and PTT

- 3.5 mm TRS CAT jack. Signal level is selectable by firmware (command `13`):
  - **TTL 3.3 V / 5 V:** a bidirectional level shifter (TXS0102 or discrete MOSFETs). This covers the Yaesu FT-817/857/897 and many QRP rigs.
  - **RS-232:** MAX3232 (or a lower-power equivalent). Shut it down when not in use.
  - **Icom CI-V:** single-wire open-collector bus with TX and RX tied together. Firmware drops its own echoed bytes.
- **PTT output:** open-drain N-MOSFET (AO3400) or an optocoupler (PC817) for full isolation (assembly option). Rated for at least 30 V, 100 mA. It goes to both the TRRS PTT pin and the CAT jack sleeve option. A red LED lights while PTT is on.

## 9. Radio-side USB host

### 9.1 Serial chips (phase 2)

Supported: USB CDC-ACM (QMX, QDX, most modern radios), CH340/CH341 ((tr)uSDX), CP210x (Icom, Yaesu, Digirig Mobile), FTDI, PL2303.

- On enumeration, the box reports VID/PID and chip type in status message `21`. Firefly uses that to suggest the matching rig preset.
- Composite radios such as the QMX expose both audio and serial. The box opens the serial interface in phase 2 and adds audio in phase 4.

### 9.2 (tr)uSDX single-cable mode (phase 3)

The (tr)uSDX firmware can stream audio over its CAT serial link. The details below come from community drivers ([miltonics/truSDX-Linux](https://github.com/miltonics/truSDX-Linux), [olgierd/trusdx-audio](https://github.com/olgierd/trusdx-audio)) and need verifying against current firmware:

- `UA1;` turns streaming on with the speaker on, `UA2;` with the speaker off, `UA0;` turns it off.
- **Receive:** unsigned 8-bit samples at about 7820–7825 Hz, framed as `US…;`. The box strips the framing, upsamples to 48 kHz and sends it as UAC audio.
- **Transmit:** the box sends `TX0;`, then unsigned 8-bit samples at about 11520 Hz downsampled from the phone's 48 kHz, then `;RX;` when PTT drops.
- The box replaces any transmit sample equal to `;` (0x3B) with 0x3C, so a sample can't end the stream early.
- At 115200 baud the link is completely full while transmitting, so the box queues CAT traffic from the phone until receive resumes.
- The box measures the real receive sample rate from byte arrival times and adjusts the resampler to match.
- Expect lower quality: 8-bit audio gives about 46 dB of dynamic range. Label this mode experimental in the app.

### 9.3 USB audio pass-through (phase 4)

- The box acts as a UAC1/UAC2 **host** for the radio's sound card (the QMX is 48 kHz, 24-bit stereo) and relays the audio to the phone-side UAC2 device.
- **Clock matching:** the box measures the radio's real sample rate and drives the phone-side feedback endpoint to match it, so the phone follows the radio's clock. If that isn't possible, fall back to an adaptive resampler (drop or repeat a sample, or a polyphase resampler).
- Few embedded USB stacks can host a USB sound card. Plan on custom host-side isochronous code. This phase is the main firmware risk.
- Bandwidth: 48 kHz × 24-bit × 2 channels = 288 kB/s each way, which fits on a full-speed link. Confirm the QMX enumerates at full speed. It should, as an STM32-based design.

## 10. MCU and firmware

| Option | USB | Pros | Cons |
|---|---|---|---|
| **Teensy 4.1** (i.MX RT1062), prototype | 2 × high-speed with built-in PHYs | Teensyduino's "Serial + MIDI + Audio" USB type already exists. Its USBHost_t36 library hosts CDC, FTDI, CH341, CP210x and PL2303. A working prototype in days | 100+ mA. The Teensy audio library runs at 44.1 kHz. Costs more |
| **RP2350**, production | 1 × native full-speed + PIO-USB host (full-speed) | Cheap, low power. TinyUSB supports a UAC2 + MIDI composite device, and has CDC, CH34x, CP210x and FTDI host drivers | Full speed only. UAC host is still custom code |
| ESP32-S3 | 1 × OTG | Cheap | Only one USB controller |
| STM32H7 | High-speed (external ULPI PHY) + full-speed | Two real controllers | More parts, more power |

**Recommendation:** prototype phases 1–2 on a Teensy 4.1 with the audio shield. Design the production board around an RP2350 with TinyUSB, unless phase 4 turns out to need high-speed host.

## 11. Firefly app changes (later, not part of the hardware work)

Notes for when the hardware exists. Nothing here is implemented, and the app stays unchanged until a prototype works.

- **`MIDISerialTransport: ByteTransport`** ([Transports.swift](../JS8Call/Radio/Transports.swift)):
  - Find the device by its CoreMIDI endpoint name, then send `20` and wait for `21`.
  - `write(_:)` → cmd `01`. Incoming cmd `02` → `onData`.
  - `setRTS` / `setDTR` → cmd `11`.
  - Reconnect on CoreMIDI setup-change notifications.
- New `RigConnection.fireflyLink`, titled "Firefly Link (USB-C)", available on iOS and macOS.
- New `PTTMethod` that keys the box's PTT line (cmd `12`), alongside the existing CAT PTT.
- Audio needs no changes: the box is a normal USB sound card, so `isUSBInterfaceConnected` and `usbInterfaceName` already work.
- Settings shows the detected radio from status `21` and offers the matching preset.
- Mac and Android can use the same SysEx protocol. A Mac can also just use the radio's USB serial directly.

## 12. Mechanical and RF

- Small aluminium or plastic enclosure. Use a captive USB-C cable or a locking receptacle, since the phone end is what usually gets yanked.
- Ferrite or common-mode chokes on both USB lines and on the audio and CAT leads. TVS diodes on every external jack.
- Ground plane, with the analog section kept away from the MCU and the switching load switch.
- LEDs: power, link (MIDI hello done), PTT.

## 13. Phase plan and exit criteria

| Phase | Builds | Done when |
|---|---|---|
| 0 | Teensy + audio shield breadboard. Firmware: UAC + MIDI echo | iPhone shows the audio route and Firefly sees the MIDI port. Current measured at the phone |
| 1 | Codec, TRRS, CAT jack, PTT. A small MIDI test app (Firefly support comes after) | From an iPhone test app, an FT-891 (or similar) changes frequency, keys PTT, and passes audio both ways |
| 2 | USB host serial | A (tr)uSDX with the Digirig uSDX cable plus USB CAT keys and tunes from the iPhone |
| 3 | (tr)uSDX stream mode | A (tr)uSDX decodes and transmits JS8 over one USB cable |
| 4 | USB audio pass-through | A QMX decodes and transmits with CAT through the box, with no drift over a 1-hour run |
| 5 | Production board on RP2350, enclosure | Phase 1–4 tests pass on the production hardware |

## 14. Open questions

- Does iOS accept the exact UAC2 + MIDI composite descriptors? Test in phase 0 on iPhone and iPad, both USB-C and Lightning (with Apple's camera adapter).
- Real power limits on iPhone 15, 16, and 17, and whether they're lower while the phone is on battery.
- Is the Digirig TRRS pinout documented well enough to copy, or do we confirm it with a meter on a real cable?
- (tr)uSDX stream details on current firmware: exact rates, `US` framing, and how the radio handles 0x3B.
- Does the QMX enumerate at full speed or high speed? Does it put up with a non-PC host?
- A MIDI Association manufacturer ID and USB VID/PID for a product.
- App Review: tunnelling CAT over SysEx should be fine, since firmware updaters do the same, but say so in the review notes.
