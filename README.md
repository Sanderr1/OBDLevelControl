# OBDLevel

An iOS app that talks to an **OBDeleven** adapter over BLE and speaks **UDS (ISO 14229)** directly —
no OBDeleven account, no cloud, no ODX download.

Reads air-suspension heights, runs and stops routines (vent front axle, vent rear axle,
level control off/on), and includes scanners so you can find your own car's DIDs and routine ids.

Everything documented below was recovered from the Android client (`com.voltasit.obdeleven`)
with jadx. Nothing here is guessed.

---

## Contents

1. [What works and what can't](#1-what-works-and-what-cant)
2. [Hardware](#2-hardware)
3. [Wire protocol](#3-wire-protocol)
4. [Command reference](#4-command-reference)
5. [UDS services used](#5-uds-services-used)
6. [Sequence: opening an ECU](#6-sequence-opening-an-ecu)
7. [Reading heights](#7-reading-heights)
8. [Running routines](#8-running-routines)
9. [Security access](#9-security-access)
10. [Where the IDs come from](#10-where-the-ids-come-from)
11. [Finding your car's IDs](#11-finding-your-cars-ids)
12. [Building the app](#12-building-the-app)
13. [Using the app](#13-using-the-app)
14. [Project layout](#14-project-layout)
15. [Reverse-engineering notes](#15-reverse-engineering-notes)
16. [Troubleshooting](#16-troubleshooting)
17. [Safety](#17-safety)
18. [Limits and known gaps](#18-limits-and-known-gaps)

---

## 1. What works and what can't

| | Status |
|---|---|
| BLE link to 2nd-gen adapter | works |
| Raw UDS over ISO-TP (CAN) | works |
| Read DIDs (live values, heights) | works |
| Start / stop / poll routines (`31 01`, `31 02`, `31 03`) | works |
| Session control (`10 03`), tester present (`3E 00`) | works |
| Security access (`27 01`/`27 02`) | implemented, key algorithm must be supplied |
| K-line / KWP2000 transport selection | selectable (`20 05`), KWP framing not implemented |
| 1st-gen adapter on iOS | **impossible** (Classic SPP, needs MFi) |
| Named basic-setting list ("Vent front axle" as a label) | **not available** — the names live in the ODX pack, not the app |

---

## 2. Hardware

| | 1st gen | 2nd gen (white) |
|---|---|---|
| Radio | Bluetooth Classic SPP | BLE |
| Service UUID | `00001101-0000-1000-8000-00805F9B34FB` | `FFE0` (data), `FFE3` (control / firmware) |
| Characteristic | — | `FFE1` (write + notify), `FFE4` (control) |
| iOS | **no** | yes |

In the APK these are two separate classes: `ClassicBluetoothDevice` (RFCOMM socket) and
`LeBluetoothDevice` (GATT). The old dongle is a serial-port-profile device — Apple requires MFi
certification for SPP, so CoreBluetooth will never see it. Use the 2nd-gen adapter.

### Generations

The adapter reports its own generation: command `08` returns `08 00 <gen>`
(`ReadDeviceGenerationCommand` in the APK).

| Gen | Hardware | Generation byte |
|---|---|---|
| 1 | classic SPP | 1 |
| 2 | BLE | 2 |
| 3 | **Pro 3**, BLE | 3 |

**Pro 3 works with this app.** It answers generation `3` on the same command channel, and the
frame set (`08`, `20`, `21`, `22`) is unchanged. The Link tab shows the generation as soon as the
characteristic subscribes, so you can verify the link before touching an ECU.

"Pro" is the subscription tier that unlocks basic settings *inside the official app*. It has no
bearing here — the ECU does not know or care which plan you bought.

**Characteristic details**

- Write to `FFE1`, notifications from `FFE1`. Enable notifications right after discovery.
- Maximum **20 bytes per GATT write**. The Android client buffers exactly 20 bytes
  (`byte[20]`) and flushes when full.
- Writes use *write with response*; the client waits for `didWriteValueFor` before the next chunk.
- `FFE4` is only used for firmware update, info packets and target configuration. Normal
  diagnostics never touch it.

---

## 3. Wire protocol

Binary, not ASCII hex. Three frame types:

### Request / response

```
request   21 <lenLo> <lenHi> <payload...>
response  21 <err>   <lenLo> <lenHi> <data...>
```

- `err == 0` means success. Anything else aborts the command (the Android client throws
  `CommandException(err)`).
- `len` is little-endian and counts **payload bytes only**, not header.
- `payload` is the **raw UDS request** — e.g. `22 F1 87`, `31 01 03 21`, `10 03`.
- `data` is the raw UDS response, e.g. `62 F1 87 00 1A`.

### IOCTL

```
request   22 <sub> <data...>
response  22 <err> <data...>
```

| sub | meaning | payload |
|---|---|---|
| `00` | CAN receive filter (rx id) | 4 bytes, big-endian CAN id |
| `01` | CAN transmit id (tx id) | 4 bytes, big-endian CAN id |

Response has **no length field** — the whole remainder of the frame after `err` is the payload.
Send these one at a time and let each notification complete.

### Protocol select

```
request   20 <proto>
response  20 <err>
```

| proto | transport |
|---|---|
| `00` | null / disconnect |
| `01` | CAN (raw) |
| `02` | ISO-TP (ISO 15765-2) |
| `03` | TP20 |
| `04` | TP16 |
| `05` | K-line |
| `06` | ISO-TP OBD2 |

For UDS on CAN you want `02`.

### Example: trivial exchange

```
> 20 02
< 20 00
> 22 00 00 00 07 7E
< 22 00
> 22 01 00 00 07 14
< 22 01
> 21 02 00 10 03
< 21 00 02 00 50 03
```

`50 03` = positive response to `10 03`, extended session active.

---

## 4. Command reference

| Frame | Direction | Meaning |
|---|---|---|
| `20 <proto>` | host → adapter | select transport |
| `20 <err>` | adapter → host | protocol set result |
| `21 <lo> <hi> <uds>` | host → adapter | UDS request |
| `21 <err> <lo> <hi> <data>` | adapter → host | UDS response |
| `22 00 <id4>` | host → adapter | set CAN rx filter |
| `22 01 <id4>` | host → adapter | set CAN tx id |
| `22 <err> <echo…>` | adapter → host | ioctl result |

Timing rules taken from the client:

- Command timeout **5000 ms** (`Command` default), session keep-alive every **2000 ms** while
  connected, **1000 ms** on KWP.
- The client serialises commands through a single queue — never fire two requests concurrently.
  This app does the same with a continuation gate.
- 15 ms settle time between commands is enough on real hardware.

---

## 5. UDS services used

| Purpose | Request | Positive response | Notes |
|---|---|---|---|
| Diagnostic session | `10 03` | `50 03` | 03 = extended |
| Tester present | `3E 00` | `7E 00` | keep-alive |
| Read data by identifier | `22 <hi> <lo>` | `62 <hi> <lo> <data…>` | live values, heights |
| Security access — seed | `27 01` | `67 01 <seed>` | level 01 |
| Security access — key | `27 02 <key>` | `67 02` | key from seed |
| Routine control — start | `31 01 <hi> <lo> [params]` | `71 01 <hi> <lo> <status>` | |
| Routine control — stop | `31 02 <hi> <lo>` | `71 02 …` | |
| Routine control — results | `31 03 <hi> <lo>` | `71 03 <hi> <lo> <status>` | poll this |

### Negative responses

`7F <service> <code>` — the app decodes these:

| Code | Name | Handling |
|---|---|---|
| `0x10` | generalReject | surface |
| `0x11` | serviceNotSupported | surface |
| `0x12` | subFunctionNotSupported | surface |
| `0x13` | incorrectMessageLength / bad length | surface |
| `0x21` | busyRepeatRequest | **retry, up to 3×** |
| `0x22` | conditionsNotCorrect | surface (usually ignition/hood/engine state) |
| `0x23` | routineNotComplete | **retry, up to 3×**, and treated as "still running" while polling |
| `0x24` | requestSequenceError | surface |
| `0x31` | requestOutOfRange | wrong DID/RID |
| `0x33` | securityAccessDenied | run security access first |
| `0x35` | invalidKey | wrong key algorithm |
| `0x36` | exceededAttempts | **stop — ECU is locking out.** Cycle ignition, wait |
| `0x37` | requiredTimeDelayNotExpired | wait, then retry |
| `0x78` | responsePending | keep waiting |

`0x36` is the one that bites people. Three bad keys in a row and the ECU refuses for the rest
of the ignition cycle, sometimes longer.

---

## 6. Sequence: opening an ECU

```
1. set protocol       20 02                       ISO-TP
2. set rx filter      22 00  <rxId 4 bytes>      response id of the ECU
3. set tx id          22 01  <txId 4 bytes>      request id of the ECU
4. extended session   31-len 10 03               → 50 03
5. tester present     3E 00 (every 2 s)          → 7E 00
```

The app does steps 1–4 in `connectECU()`, and sends `3E 00` once as a sanity check. Add a
repeating keep-alive if you plan to sit on a session for minutes; most ECUs drop back to default
session after ~5 s without traffic.

TX/RX ids are in **Config**. Typical 11-bit UDS pairs (engine/transmission style) use
`0x7E0/0x7E8`; the air-suspension ECU on most VAG cars is somewhere in `0x7xx`. If you don't know
them, read them out of the ODX pack or sniff them with a CAN logger while OBDeleven connects.

---

## 7. Reading heights

Heights are **not basic settings** — they are live values, read with `22 <did>`.

```
> 21 03 00 22 2B 0F
< 21 00 05 00 62 2B 0F 01 9A
                    └──┬──┘ └┬─┘
                     header  data (2 bytes)
```

Decoding is per channel, configured in **Config → Height channels**:

| Field | Meaning |
|---|---|
| `DID` | identifier, hex |
| `len` | payload bytes to consume (1–4) |
| `signed` | two's complement |
| `scale` | multiplier |
| `offset` | added after scaling |

Most air-suspension ECUs report tenths of a millimetre, so `len 2`, `signed on`, `scale 0.1`
gives millimetres directly. Confirm by watching the number change when you push down on a corner.

Typical set to hunt for (four corners + computed level):

- front left, front right, rear left, rear right sensor heights
- vehicle level / deviation from nominal
- compressor status, system pressure, accumulator pressure

If all four read `0.0` or a constant, it's a wiring or sensor fault — recalibration will not fix it.

---

## 8. Running routines

Basic settings are **routine control**. That is all they are — the app just gives them names from
the ODX file.

```
start    31 01 <ridHi> <ridLo> [params]
poll     31 03 <ridHi> <ridLo>          every ~400 ms
stop     31 02 <ridHi> <ridLo>
```

Result payload after `71 03 <ridHi> <ridLo>`:

| Status | Meaning |
|---|---|
| `00` | not active / idle |
| `01` | running |
| `02` | finished, success |
| `03` | finished, error |

`runRoutine()` in `ECUConnection` starts, polls until status is `00/02/03`, and gives up after
90 s. While polling, NRC `0x23` (`routineNotComplete`) is treated as "still running", not an error.

Some routines take parameters. In the Android app, `GetBasicSettingRequestParamUC` builds a
parameter block for those — e.g. calibration routines want the measured heights typed in. Wire
those into `RoutineAction.parameters` (raw bytes) when you find one that needs them.

Routines that need the **hood open** are gated by the ECU, not the app: the original client reads
a flag first (`isPopTheHoodRequired`) and disables the button. If yours returns NRC `0x22`,
that is why.

---

## 9. Security access

```
> 27 01
< 67 01 <seed…>
> 27 02 <key…>
< 67 02
```

Implemented in `ECUConnection.securityAccess(level:keyAlgorithm:)`. The seed→key algorithm is
**per manufacturer and lives server-side** in the OBDeleven ecosystem — it is not in the APK in
usable form. Supply your own closure:

```swift
try await ecu.securityAccess(level: 0x01) { seed in
    // your algorithm
    return key
}
```

Without it you get `0x33 securityAccessDenied` on anything that writes.

**Do not brute force keys.** `0x36 exceededAttempts` locks the ECU and increments an attempt
counter that some modules persist.

---

## 10. Where the IDs come from

They are not in the APK. The full chain, verified:

1. `ServerApiImpl.getOdxListByPlatform` / `getOdxListByName` fetch an **ODX pack** from the server,
   resource key `"ODX"`, per platform or per name.
2. `OdxRepositoryImpl` / `OdxWorkerRepositoryImpl` parse it with SimpleXML into `DIAG-LAYER`,
   `BASIC-STRUCTURE`, `PARAMS`, `REQUESTS`, `POS-RESPONSES`.
3. `GetBasicSettingsUC` builds the list the UI shows.
4. Display names come from `Texttabe.c("MAS00112")`-style ids resolved against a translation
   table that is also not bundled.

The APK has **no strings.xml, no bundled resources, no hardcoded DID or RID table**. That is why
this app starts blank and ships scanners instead of a fake list.

---

## 11. Finding your car's IDs

### Routines

**Config → Scan routines**, start `0000`, count `64`. It sends `31 03 <rid>` for each id and logs
every one that answers `71 03`. Repeat with `0064`, `0128`, … A handful of ids will respond; those
are your basic settings. Cross-reference the order against what OBDeleven lists on Android
(`34 – Level Control → Basic Settings`) to label them.

### DIDs

**Config → Scan DIDs**:

1. Start `F180`, count `32` — identification block, always answers on UDS ECUs.
2. Then walk `2B00`–`2BFF` and `0100`–`01FF`, which is where VAG puts live values.
3. Watch each result while pushing on a corner — the four that track your hand are the height sensors.

### From the ODX file

If you want the real thing: pull the ODX file from the Android app's cache
(`/data/data/com.voltasit.obdeleven/…`, needs root) or intercept the `"ODX"` request. Inside,
`<ROUTINE ID="…">` and `<DATA-OBJECT-PROP>` give you the ids and the scaling — the same numbers
you'd otherwise find by scanning.

---

## 12. Building the app

### Requirements

- macOS with Xcode 15+ (iOS 17 SDK)
- iOS 17 device (**the simulator has no Bluetooth**)
- 2nd-gen OBDeleven adapter

### With XcodeGen

```bash
brew install xcodegen
cd OBDLevelControl
xcodegen generate
open OBDLevel.xcodeproj
```

Set your signing team, pick your iPhone, run.

### Without XcodeGen

1. Xcode → new iOS App → name `OBDLevel`, SwiftUI, Swift.
2. Delete the generated `ContentView.swift` and `OBDLevelApp.swift`.
3. Drag the `OBDLevel/` folder into the project (Copy items, Create groups).
4. Target → Info → add `NSBluetoothAlwaysUsageDescription`:
   `Connects to the OBDeleven adapter to read suspension heights and run routines.`
5. Build.

### Entitlements / permissions

Only Bluetooth. No background modes needed — the app must be in the foreground to hold the link.

---

## 13. Using the app

**Link**
- Scan → tap the adapter.
- Once `ready`, Open ECU uses the TX/RX ids from Config and enters extended session.

**Heights**
- Read now, or auto-refresh every 2 s.
- Each row shows the decoded value and the raw response bytes, so you can sanity-check scaling.

**Actions**
- One row per routine. Run asks for confirmation (the car moves), then starts and polls.
- Stop sends `31 02` for that RID.
- Rows with `no routine id` are disabled — fill the id in Config.

**Config**
- CAN ids, height channels (DID/len/scale/offset/signed), routine ids.
- DID scanner and routine scanner.
- Restore defaults.

**Console**
- Type any UDS request as hex (`22 F1 90`, `31 01 03 21`, `10 03`) and send.
- Every frame in and out is logged with direction arrows.
- Use this to poke at things before wiring them into the UI.

---

## 14. Project layout

```
OBDLevelControl/
├── project.yml                            XcodeGen manifest
├── README.md
└── OBDLevel/
    ├── OBDLevelApp.swift                  @main, wires transport + service
    ├── Transport/
    │   ├── OBDelevenTransport.swift       BLE, 20-byte chunking, frame parser,
    │   │                                  command gate, timeouts, logging
    │   └── ECUConnection.swift            UDS: session, DID read, routines,
    │                                      NRC retry, security access
    ├── Vehicle/
    │   └── LevelControlService.swift      profile persistence, channel decode,
    │                                      actions, DID/RID scanners
    └── UI/
        └── ContentView.swift              Link, Heights, Actions, Config, Console
```

Key types:

| Type | Role |
|---|---|
| `OBDelevenTransport` | owns the `CBCentralManager`, builds frames, serialises commands, parses replies |
| `DeviceProtocol` | transport selector (`20 xx`) |
| `OBDError` / `NRC` | error + negative-response decoding |
| `ECUConnection` | UDS layer, one instance per ECU address pair |
| `HeightChannel` | DID + decoding recipe |
| `RoutineAction` | RID + parameters + confirm flag |
| `LevelControlService` | observable state for the UI, persists profile in `UserDefaults` |

---

## 15. Reverse-engineering notes

For anyone reproducing or extending this, the Android classes that revealed each piece:

| Android class | What it established |
|---|---|
| `utils.bluetooth.LeBluetoothDevice` | BLE path: service `FFE0`/char `FFE1`, 20-byte buffer, `writeValue` |
| `utils.bluetooth.ClassicBluetoothDevice` (`g`) | 1st gen is RFCOMM SPP, not BLE |
| `com.obdeleven.service.core.d` (`Command`) | 5 s timeout, single global command chain |
| `com.obdeleven.service.core.gen1.i` (`RequestCommand`) | `21 <lenLo> <lenHi> <payload>` framing, response `21 <err> <len> <data>` |
| `com.obdeleven.service.core.gen1.c` (`IoCtlCommand`) | `22 <sub> <data>` framing, response `22 <err> <data>` |
| `com.obdeleven.service.core.gen1.SetProtocolCommand` | `20 <proto>`, protocol id table |
| `com.obdeleven.service.protocol.f` (`UdsProtocol`) | UDS payloads go through untouched; `1001` on connect, `3E00` keep-alive |
| `com.obdeleven.service.protocol.Kwp2000Protocol` | KWP framing: format byte, target, `F1`, data, checksum |
| `p230s8.a` (`UdsProtocolRequestCommand`) | positive response = request SID + `0x40`; `7F` = NRC |
| `domain.usecases.device.s` / `.t` | `22 00 <rxId>` filter, `22 01 <txId>` |
| `domain.usecases.device.p` (`SendProtocolRequestUC`) | one command in flight, hex string in/out |
| `domain.usecases.device.requests.c` (`RequestUdsUC`) | retries on NRC `0x21`/`0x23`, max 3 |
| `domain.usecases.controlUnit.basicsetting.StartBasicSettingUC` | routines via ODX `DIAGLAYER`, saves history |
| `domain.timers.BasicSettingStatusTimer` | status is polled, not pushed |
| `domain.usecases.odx.GetBasicSettingsUC` | list comes from ODX, not a local table |
| `presentation.basicsettings.a` (`UDSBasicSettingsViewModel`) | hood flag gate, security access flow, `MAS00112` status text |
| `com.obdeleven.service.model.BASICSTRUCTURE` / `DIAGLAYER` | ODX XML schema used |

---

## 16. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| No devices in scan | adapter is 1st gen, or not powered | 1st gen won't work on iOS; plug into OBD port for power |
| `bluetooth state 5` (unauthorized) | permission denied | Settings → Privacy → Bluetooth → allow the app |
| Connects, `ready` never true | `FFE1` not found | dongle firmware mismatch — update it via OBDeleven on Android once |
| Everything times out | wrong TX/RX ids | try `7E0`/`7E8` first, confirm with a CAN log |
| `NRC 0x7F 0x22 conditionsNotCorrect` | ignition off, hood closed, engine state | ignition on, hood open if the routine needs it |
| `NRC 0x33 securityAccessDenied` | ECU wants seed/key | supply the key algorithm |
| `NRC 0x36 exceededAttempts` | too many bad keys | **stop**, cycle ignition, wait; don't retry blindly |
| `NRC 0x31 requestOutOfRange` | DID/RID doesn't exist on this ECU | scan the range, don't guess |
| Values look like nonsense | wrong scale/offset/length | compare against raw bytes in the row, adjust in Config |
| Routine hangs at `running` | ECU waiting on a condition | press Stop, check hood/doors/level ground |
| Writes stall mid-frame | not waiting for `didWriteValueFor` | this app waits; if you fork it, keep that |

---

## 17. Safety

The car physically moves. Air suspension basic settings bypass normal levelling logic.

- **Level ground, wheels on the ground, ignition on, charger connected.** The compressor pulls
  30–40 A and will flatten a battery fast.
- Venting has **no lower limit protection** in basic-setting mode. Watch the wheel arches, not the
  screen. Stop if a corner drops onto the bump stop.
- Don't drive with level control deactivated.
- Keep hands and tools out of the arches while a routine runs.
- Don't run calibration until you've confirmed all four sensors read sane, changing values.
- Repeated failed security access can lock a module until ignition cycle — or longer.

This is a diagnostic tool, not a toy. A wrong RID can command a valve or a compressor.

---

## 18. Limits and known gaps

- **No KWP2000 framing.** `20 05` (K-line) can be selected, but the payload wrapper
  (format byte / target / checksum) is not implemented — only UDS. Older air-suspension ECUs
  that speak KWP need that layer added; the algorithm is documented in the table above.
- **No ODX import.** The app never reads ODX files. If you want real names and scaling, parse the
  pack yourself and feed the values into `HeightChannel` / `RoutineAction`.
- **No security key algorithms.** Deliberately left as a closure.
- **No firmware update path.** `FFE3`/`FFE4` handling (`writeInfoPacket`, `writeTargetConfig`,
  `bootIntoFWUpdateMode`) was left out on purpose — getting it wrong bricks the adapter.
- **Single ECU at a time.** The transport serialises everything; multi-ECU scanning would need a
  session manager on top.
- **No background operation.** iOS suspends BLE when the app leaves the foreground unless you add
  the bluetooth-central background mode, which this doesn't declare.
- **Untested on hardware.** Written from the protocol, not from a live car. Expect to adjust
  TX/RX ids and scaling first, and treat the very first routine run as a test.

---

## Licence / intent

Personal diagnostic tooling for your own car. Reading live values is passive. Routines write to
the ECU — that is the point of the app, and that is also what can break something if you point it
at the wrong id.
