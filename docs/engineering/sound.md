# Sound

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableKit/Audio.swift`, `DozSound.swift`; `Sources/DozableHost/MacAudio.swift`, `Microphone.swift`, `HostCore+Sound.swift`; `Guest/sound-kernel/` | 667: sound — the sound kernel's pin, the device (microphone source only when allowed); `SoundMode` (`sandbox.audio`), macOS's microphone permission and its seam, the per-boot decision; the kernel's reproducible recipe and source offer; `AudioTests`, `AudioHostTests` |

## Sound (604 experimental → 667)

- **`sandbox.audio` = off | speakers | on, per sandbox** (`SoundMode`, `HostCore+Sound.swift`): `doz create --sound
  MODE` (`--audio` = on), New sandbox › Bridges › Sound, `audio:` in doz_project.yaml, else the setting. The DEVICE is
  chosen at create (`resolveSound` → `SandboxSpec.audio`); afterwards only speakers ↔ on (`SoundMode.changeProblem`).
  `SandboxSpec.audio` nil = no sound: no device, the pinned kernel, and the spec and `ToolInputs` encode byte-identically
  (`AudioTests`). `PinnedIdentity.audio` adds the virtio-snd device; `VMLayout` records it, so a mismatched restore is
  refused. The VM boots `SoundKernel` (`vmlinux-6.18.15-186-sound2`, sha256 pinned in `Audio.swift`) from the kernel
  CACHE — the host copies it there, verified, at create and before every boot (`MacAudio.installSoundKernel`); bakes
  and image keys keep the pinned kernel. Never downloaded: `release.sh` ships it (`SOUND_KERNEL`, sha256-checked,
  `libexec/doz/kernels/`, its source offer in `licences/sound-kernel/`); dev: `DOZ_TEST_SOUND_KERNEL`. A public build
  has none (`BuildFlavor.audioMissing`).
- **The kernel is OURS (GPL-2.0)**: `Guest/sound-kernel/` — `sound.conf` (four options, nothing outside sound),
  `build-in-guest.sh` (reproducible: fixed KBUILD_* and the SAME build
  directory — the vDSO's build-id hashes it), the complete `sound.config`, kata's patch, `PROVENANCE.md` (the written
  offer). A new kernel gets a NEW file name: a sandbox that slept under the old one finds it for its restore.
  `make sound-kernel` (`Scripts/sound-kernel.sh`: the pinned kernel's config → `doz-vmtest spike-build` in a throwaway
  ubuntu:22.04 VM → sha256 == `SoundKernel.sha256` and config == `sound.config`, ~7.5 min) is the check; CI runs it
  (`.github/workflows/sound-kernel.yml`, doz-ci, dispatch + paths) and publishes the kernel as an artifact.
- **The microphone is the Mac's only when macOS has ALREADY said yes** (`MicrophoneDecision`, `settleMicrophone` before
  every boot): otherwise the input stream has NO source (`AudioDevice`: the device is the same, the guest records
  silence) and Virtualization never asks macOS. That removes 604's "VM stops when paused with the question pending" and
  "a recording opened before Allow stays stuck" by construction. **The source is in VZ's SAVED STATE** (a restore with
  another source fails "file format is not compatible" — measured both ways): `PersistedSandbox.microphoneSource`
  records it at a cold boot and every restore uses it (nil = an older build's VM: the real source); a new decision
  waits for the next cold boot. doz asks (`AVCaptureDevice.requestAccess`, the ONE AVFoundation file `Microphone.swift`
  — audit) when `sandbox.microphone_ask` says (`MicrophoneAsk`, owner 2026-10-27): `first_recording` (default) — the
  host watches a RUNNING `on` sandbox whose VM has a silent microphone while macOS is undecided
  (`HostCore.watchForRecording`: one guest stream, `DozSound.recordingWatchScript`, reads
  `/proc/asound/card*/pcm*c/sub*/status` once a second — a sound sandbox's container has `/proc/asound` UNMASKED,
  `Sandbox.maskedPaths(sound:)` — and prints `doz-recording` when a capture substream RUNS; ended by `finishInput` before
  every non-boot lifecycle op, on leaving running and at quit), then asks (one question at a time,
  `microphoneAsking`) and says — a note + a `microphone` viewer notice — that THIS recording stays silent and Shut Down
  + Start gives the Mac's microphone (`MicrophoneDecision.answeredAtRecording`); `first_start` — a cold boot asks and
  waits at most `microphoneQuestionWait`. **Tests never reach the real permission**: `MicrophoneAccess.current` is the
  seam in every guarded run and XCTest (`DOZ_TEST_MICROPHONE`, `DOZ_TEST_MICROPHONE_ANSWER` — the seam remembers its
  answer, as macOS does).
- **macOS asks about the microphone for the host's RESPONSIBLE app** (the app that started doz — survives the detached
  double spawn), named in host.log, `host status` `microphoneApp`, `doctor` and doz-sound's hint.
- **604's "a stream open across a restore stalls" no longer happens** (667, three runs: playback and capture held
  open across pause, sleep, hibernate and a new host process, default and 10 ms periods, kept real time —
  workspace `probes/667-*/remeasure.sh`). Nothing re-syncs streams at a wake; the remedy built and dropped is in the
  667 plan, if it ever comes back.
- **The tools layer** (sound only): alsa-utils, `/etc/asound.conf` (stamp v2: `default` = asym of the card's
  playback/capture devices — NOT dmix, which stalls on this card), and `doz-sound` v3 (`DozSound.swift`; its conf
  carries `MIC` — "mac" or why the microphone is silent).
