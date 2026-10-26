# Sound

> **Not in public releases yet.** The releases on Homebrew and GitHub do not include sound: `--sound` says so. This
> page describes a build that carries the sound kernel (`make release PUBLIC=0`).

A sandbox can have sound: programs in it play through your Mac's speakers and, if you want, record from its
microphone. It is a setting, `sandbox.audio`, off unless you choose it:

| value | what the sandbox gets |
|---|---|
| `off` (the default) | no sound device — exactly as every other sandbox |
| `speakers` | the Mac's speakers; its microphone records silence, and macOS is never asked about it |
| `on` | the Mac's speakers and its microphone, once macOS allows it |

## Make one

```sh
doz create a1 --image lab --sound on      # or --sound speakers; --audio is the same as --sound on
doz start a1
doz exec a1 -- doz-sound test
```

In the dashboard: **New sandbox › Bridges › Sound**. In a project file: `audio: on`. To give every new sandbox
sound: `doz config set sandbox.audio speakers`.

Sound is a device in the sandbox's virtual machine, so it is chosen when the sandbox is created. Afterwards a sandbox
can move between `speakers` and `on` (`doz config set --sandbox a1 sandbox.audio on`) — from its next start; a wake
keeps what it slept with — but not to or from `off`: for that, create a new sandbox.

A sandbox with sound boots its own Linux kernel: the same one every sandbox uses, with ALSA and the virtio sound
driver added. It ships with doz (never downloaded), and `doz doctor` says whether this doz carries it. It is
kata-containers' kernel 6.18.15-186 (kata 3.28.0: its config and patch, unchanged) with four options added —
`CONFIG_SOUND`, `CONFIG_SND`, `CONFIG_SND_VIRTIO`, `CONFIG_SND_PROC_FS` — and nothing else; its recipe, the complete config and the source offer are in Dozable's source (`Guest/sound-kernel/`)
and in a release's `licences/sound-kernel/`.

## Inside the sandbox

The tools layer ([The tools layer](19-the-tools-layer.md)) sets a sandbox with sound up at every start and wake:
ALSA's tools (`aplay`, `arecord`), an `/etc/asound.conf` that makes the sound card ALSA's default (one program
at a time can play, and one can record — a second gets "Device or resource busy"), and `doz-sound`:

| command | does |
|---|---|
| `doz-sound info` | the sound card, its devices, the default, and the microphone (the Mac's, or why it is silent) |
| `doz-sound test` | plays a quiet tone (under a second), records 3 seconds, says the level, plays it back |
| `doz-sound rec FILE [SECONDS]` | records a WAV file (5 seconds unless you say) |
| `doz-sound play FILE` | plays a WAV file |
| `doz-sound tone FILE` | writes a quiet test tone (a WAV, under a second) to play |

Any program that uses ALSA's default device works the same way.

## The microphone and macOS

macOS asks about the microphone for the **app that started doz** — Terminal, iTerm, your editor — not for doz
itself. doz settles that question **before** a sandbox records:

- When a sandbox with `on` starts and macOS has not been asked, doz asks — macOS shows its question ("Terminal
  would like to access the microphone") — and the start waits for your answer (at most a minute).
- A sandbox records from the Mac's microphone only if macOS allowed it before the sandbox started. Otherwise — not
  asked yet, denied, or the question left unanswered — it records **silence**, and `doz-sound` says why. After you
  allow it, Shut Down and Start the sandbox: a wake keeps the microphone it went to sleep with.
- `doz doctor` says macOS's answer and which app it is for; the sandbox's Home in the dashboard says what its
  microphone is. To change your answer: System Settings › Privacy & Security › Microphone.

Because the question is settled first, pausing, sleeping or hibernating a sandbox is always safe, whatever macOS's
answer.

## Across pause, sleep and hibernation

Sound keeps going across Pause, Sleep and Hibernate, and after the host restarted: a program that was playing or
recording when the sandbox went to sleep carries on when it wakes, with nothing to restart.

## Known limitations

- A recording from the Mac's microphone can start with a short stretch of silence and contain a few single-sample
  ticks (`doz-sound` leaves them out of its level).
- Sound takes a moment to reach the speakers: with the standard tools' defaults, about three quarters of a second from
  playing a sound to hearing it back through the microphone; programs that use small buffers are much quicker.
- A sandbox with sound wakes from hibernation a little more slowly (about 0.07 s).
- One player and one recorder at a time.
- Codex's voice mode does not work in a sandbox yet: it sends its sound over the network as UDP (WebRTC), which a
  proxied sandbox does not carry.
