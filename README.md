# CMF Phone 1 — stereo speaker module

Drives the earpiece as a second speaker so the CMF Phone 1 plays real stereo
instead of mono out of the bottom firing driver.

**Status: working on the CMF Phone 1** (A015 / Tetris, mt6878, Nothing OS
B4.1, Android 16). The routing below is verified on that device and ships
preconfigured. On anything else the module installs with an empty
`actions.conf` and `stereoctl probe` collects what is needed — see
[Why it ships empty elsewhere](#why-it-ships-empty-elsewhere).

---

## Install

Flash the zip in Magisk / KernelSU / APatch, reboot, then in Termux:

```sh
su
stereoctl probe
```

The report lands in `/sdcard/cmf-stereo-probe-<timestamp>/` with a `.tar.gz`
next to it. That is what gets analysed to fill in the routing.

You can also run the probe without installing anything:

```sh
su
sh /sdcard/probe.sh          # after copying scripts/probe.sh to /sdcard
```

---

## How it works

Three layers, smallest hammer first.

**1. Mixer actions (`actions.conf`).** The real work. An ALSA mixer control
somewhere enables the receiver output stage; on MediaTek there is usually also
a routing control that decides which DL (downlink) stream feeds it. Setting
those while the speaker is playing is what produces two channels.

The audio HAL rewrites mixer controls on every route change, so a one-shot
write does not survive the next stream start. A small daemon re-asserts the
values every couple of seconds and — by default — only while audio is actually
playing, so the earpiece is not left energised all day.

Everything touched has its original value saved under
`/data/adb/cmf-stereo/state/` and restored on stop, disarm or uninstall.

**2. Audio policy overlay (`stereoctl xml-patch`, optional).** If the policy
declares the speaker as `AUDIO_CHANNEL_OUT_MONO`, the framework downmixes to
one channel before the HAL ever sees it, and no amount of mixer work brings
the second channel back. The patch widens only the speaker `<devicePort>` to
stereo, in an overlay copy — the vendor partition is never written. It is
opt-in, validated before it is installed, and reversible.

**3. What the CMF Phone 1 actually needed.** Worth recording, because it was
not any of the obvious answers and the probe is what found it.

Media on this device never touches the internal codec. Playback runs:

```
DL_24CH_CH1/CH2 ──▶ I2SOUT4_CH1/CH2 ──▶ Awinic aw_dev_0 smart PA ──▶ speaker
                                  ◀── I2SIN4 ──▶ UL3   (IV-sense feedback)
```

The earpiece hangs off the internal codec's DAC (`ADDA_DL`), and that DAC
normally has **no source connected at all** — every one of its ~20 input
switches sits Off. So pointing `RCV Mux` at the receiver routes it to a
silent wire, which is exactly what happened on the first attempt.

The switch that matters is `ADDA_DL_CH1 DL_24CH_CH1`: it feeds the internal
DAC from the same `DL_24CH` stream already going to the speaker amp. Turn it
on, then open `RCV Mux`, and the earpiece plays.

There is only one Awinic device (`aw_dev_0`), so there is no second amp
channel to press into service — the internal codec was the only way in.

### No left/right split, and why

Both transducers are hard-wired to channel 1 of the DL mixer:

- **Speaker**: `I2SOUT4_CH1 <- DL_24CH_CH1` only. Cutting CH1 silences it;
  cutting CH2 changes nothing. `I2SOUT4_CH1` offers no `DL_24CH_CH2` source,
  so the speaker cannot be moved to the right channel.
- **Earpiece**: `RCV <- ADDA_DL_CH1 <- DL_24CH_CH1` only. Feeding
  `ADDA_DL_CH2` instead leaves the receiver path unpowered — visible as
  `Handset Volume` refusing to hold a non-zero value, because the register
  will not latch while DAPM has the path down.

So this module gives you both drivers playing the same content: more output
and a fuller, taller image than the single bottom speaker, but not two
independent channels. True stereo is not reachable from userspace here.

**Do not run `stereoctl xml-patch` on this device.** The mono speaker port is
what makes the framework sum L+R before `DL_24CH`, so CH1 carries the whole
mix. Widening it to stereo would put only the left channel on CH1 — and since
both outputs read CH1, the right channel would be lost entirely. The
`xml-patch` machinery stays in the module for other hardware, where the
speaker and earpiece can be fed from different channels.

MediaTek's "2nd loudspeaker" machinery (`bes_loudness_Sep_LR_Filter`,
`2nd-ACF`) is **not** present on this build, despite being the mechanism the
Hi-Res Audio module aims at. The probe still captures that tree, because on
another MTK device it may be the better route.

---

## Commands

```
stereoctl status              module, daemon, and live control values
stereoctl probe [dir]         dump the audio hardware
stereoctl report              fold the newest probe into one shareable .txt
stereoctl on | off            arm / disarm (off survives a reboot)
stereoctl solo | unsolo       speaker off, earpiece only - for auditioning
stereoctl guard on | off      re-enable / bypass the speaker-follows guard
stereoctl apply | revert      one-shot apply / restore
stereoctl restart             restart the watcher daemon
stereoctl log [n]             tail the log

stereoctl scan [pattern]      search the mixer for candidate controls
stereoctl ctl NAME [VALUE]    read or write one mixer control
stereoctl dump                every control and its value
stereoctl diff [seconds]      snapshot the mixer, wait, show what changed

stereoctl xml-patch           install the stereo speaker-port overlay (reboot)
stereoctl xml-revert          remove it (reboot)
```

`stereoctl ctl` is the one to experiment with: find a candidate with `scan`,
flip it while music plays, listen to the earpiece.

---

## Config

Lives in `/data/adb/cmf-stereo/`, survives module updates.

| file | what |
|---|---|
| `stereo.conf` | behaviour: mode, poll interval, log level |
| `actions.conf` | the routing itself, one action per line |
| `stereo.log` | what the daemon did |
| `state/` | saved original values, used to revert |

`actions.conf` syntax:

```
ctl|<mixer control name>|<value>     set an ALSA mixer control
sysfs|<path>|<value>                 write to a sysfs node
prop|<property>|<value>              set a system property
```

`MODE=playback` (default) applies the routing only while something is playing.
`MODE=always` keeps it on permanently — louder in theory, harder on the
earpiece, and it costs idle power.

`GUARD_CTL` / `GUARD_VALUE` gate the routing on a mixer control's value. On
the CMF Phone 1 the guard is `aw_dev_0_switch` = `Enable`: the HAL disables
the speaker amp when headphones or Bluetooth take over, so the earpiece
follows the speaker instead of playing to nobody. One mixer read per cycle,
no `dumpsys`.

### Earpiece gain

`Handset Volume` advertises `range 0->18`, but that ceiling is misdeclared —
the HAL's own default is 31, matching its Headset and Lineout settings. 31 is
also the true hardware ceiling: the register field is 5 bits, so 40 wraps to
8 and gets *quieter*. Measured on the device.

`ADDA_DL_GAIN` is deliberately left alone. The HAL raises it to ~63311 of
65535 by itself when a stream starts, and pinning it to maximum would also
raise headphone output, which shares the ADDA path.

---

## Why it ships empty elsewhere

The mixer control names are device-specific. A wrong write is, in ascending
order of regret: nothing, silence, a HAL crash, or an earpiece driven past
what a receiver is built for. The earpiece has a fraction of the excursion and
power handling of the main speaker and there is no protection circuit assuming
you will use it for music.

So: probe first, then fill in real names. When you find a working route, start
its gain low and raise it a step at a time. Distortion or rattle means back
off — that damage does not come back.

---

## Safety and recovery

**Boot watchdog.** If two consecutive boots fail to reach `sys.boot_completed`
while the policy overlay is active, `post-fs-data.sh` deletes the overlay
before it can be mounted again. A bad policy costs one extra reboot instead of
a trip to recovery.

**XML validation.** No patched policy is installed unless it passes a
structural check — balanced `<module>`, `<mixPort>`, `<devicePort>` and
`<route>` elements, intact root tag, no stray backslashes from a bad
insertion. Android has no `xmllint`, and a malformed audio policy takes
`audioserver` down hard enough to loop the boot.

**Manual recovery**, if you ever need it:

```sh
adb wait-for-device shell           # or hold vol-down for safe mode
su
touch /data/adb/modules/cmf_stereo/disable
reboot
```

Both Magisk and KernelSU honour the `disable` file, and `post-fs-data.sh`
never touches audio when the actions list is empty.

---

## Note on the Hi-Res Audio module

If you tried `Hi-Res Audio™ v2.0 with aaudio_mmap` and it bootlooped this
phone, that is expected, and worth knowing because it aims at the same
hardware. Its `customize.sh`:

- Inserts `<mixPort>` blocks into `audio_policy_configuration.xml` at
  **hardcoded line numbers** (`sed -i '64a\…'`, `'271a\…'`, `'302a\…'`). Those
  offsets come from other MediaTek devices. On a policy file of a different
  shape the XML lands mid-element, the file stops parsing, `audioserver`
  dies on every boot, and the phone loops. This is almost certainly what bit
  you.
- Forces `aaudio.mmap_policy=3` and `aaudio.mmap_exclusive_policy=3`
  ("always use MMAP") plus `killall audioserver`. If the HAL has no MMAP PCM
  path, that is a crash loop on its own.
- Rewrites MTK's `Playback_ParamTreeView.xml` — deleting `Field` entries and
  renaming `Feature` blocks. MTK's AudioParamParser validates that tree
  against the value XMLs in `/vendor/etc/audio_param/`; a mismatch aborts the
  audio HAL.
- Sets the speaker channel mask to `AUDIO_CHANNEL_OUT_SURROUND`, which is not
  a thing a phone speaker port supports.

The useful part is what it reveals: MTK's `2nd Loudspeaker` / `bes_loudness`
machinery, and the earpiece `<devicePort>` mono→stereo edit. Those ideas are
worth keeping. The line-numbered `sed` is not — this module uses block-aware
`awk` on the element it means to change, and validates the result.

Do not run both modules at once.

---

## tinymix

Mixer controls cannot be read or written without a `tinymix` binary, and the
CMF Phone 1 ships none. The module bundles one: a statically linked `aarch64`
build of upstream tinyalsa, hardware backend only, no `dlopen`. Provenance,
license and the exact build command are in [`bin/README.md`](bin/README.md).

If you would rather not trust a shipped binary, build it yourself and drop it
at `/data/adb/cmf-stereo/bin/tinymix` (`chmod 0755`) — that path is searched
first. Termux's `tinyalsa` package works too.

Search order: `/data/adb/cmf-stereo/bin`, the module's `bin/`, `/vendor/bin`,
`/system/bin`, `/odm/bin`, `/data/local/tmp`, then `$PATH`. A vendor-supplied
`tinymix` wins over the bundled one. Both the tinyalsa 1.x
`tinymix NAME VALUE` and the 2.x `tinymix set NAME VALUE` calling conventions
are handled, detected via `--help` rather than by guessing from an error
message.

---

## Uninstall

Remove it in your root manager. `uninstall.sh` stops the daemon and restores
every control it touched. `/data/adb/cmf-stereo/` is left in place so a
reinstall does not lose your routing; delete it by hand for a clean slate.

---

## Development

`tests/run-tests.sh` exercises the parts that do not need a phone — the action
engine's save/apply/revert cycle, the boot watchdog, the XML structural
validator, and the speaker-port rewrite (including the self-closing-element
and no-speaker-port cases). Run it on any Linux box:

```sh
sh tests/run-tests.sh
```

`./build.sh` packages the flashable zip.
