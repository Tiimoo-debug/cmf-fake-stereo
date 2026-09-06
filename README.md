# cmf-fake-stereo

A Magisk / KernelSU / APatch module that makes the **CMF Phone 1** play media
out of its **earpiece as well as its bottom speaker**.

"Fake stereo" is the honest name. It is two drivers playing the same content —
louder, fuller and taller than the single bottom-firing speaker — not two
independent channels. True left/right separation is **not possible** on this
hardware, and the [Findings](#findings-what-this-device-actually-does) section
shows the measurements that prove it rather than asking you to take my word.

Verified on **A015 / Tetris, MT6878, Nothing OS B4.1, Android 16.**

## What it does

- Plays media through the earpiece alongside the speaker, automatically
- Earpiece gain at 31 — the hardware's real ceiling, not the 18 the control advertises
- Applies only while audio is playing, so the receiver is not held energised
- Steps aside for headphones and Bluetooth
- Restores every control it touches on stop, disarm or uninstall
- Disarms itself if it ever causes a failed boot

## What it does not do

- **No left/right stereo.** Both transducers are wired to the same mixer channel.
- **No extra volume from the main speaker.** It is untouched.
- **Nothing on other devices out of the box.** It installs inert elsewhere and
  ships a probe to work out that device's routing.

## Quick start

Flash the zip (build it with `./build.sh`, or grab a release), reboot, play
something. That is the whole setup on a CMF Phone 1 — the verified routing is
preconfigured.

To check it is working, with audio playing:

```sh
su
stereoctl status     # all three controls should show want= matching now=
stereoctl solo       # speaker off, earpiece only - proves it is really the earpiece
stereoctl unsolo
```

If it is ever silent, `stereoctl doctor` walks every layer that can cause that
and names the one responsible.

## On other devices

It installs with an empty `actions.conf` and changes nothing. Run
`stereoctl probe` to dump the audio hardware — ALSA topology, every mixer
control, smart-amp drivers, HAL configs and MediaTek's AudioParam tree — then
`stereoctl report` to fold it into one shareable text file. The routing for
that device gets written into `actions.conf` from what the probe finds. See
[Why it ships empty elsewhere](#why-it-ships-empty-elsewhere).

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

## Findings: what this device actually does

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

MediaTek's "2nd loudspeaker" machinery **is** present on this build, in
`/vendor/etc/audio_param/`:

```
2nd Loudspeaker Compensation Filter (2nd-ACF)
2nd Loudspeaker High/Low Pass Filter Order
bes_loudness_Sep_LR_Filter
bes_loudness_L_*  /  bes_loudness_R_*   (separate L and R filter sets)
```

An earlier revision of this file claimed it was absent. That was wrong — it
came from the broken BRE greps fixed in the ERE commit, which reported a
clean zero for a pattern that never matched anything. Whether the feature is
merely MediaTek's stock parameter template or actually wired to a second
transducer on this hardware is unresolved.

---

## Commands

```
stereoctl status              module, daemon, and live control values
stereoctl doctor              diagnose why the earpiece is silent
stereoctl reset               clear saved state and start clean
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

## Credit: the Hi-Res Audio module

This module owes a real debt to
[**Hi-Res Audio™** by Adinata (@Adivenxnataly)](https://github.com/adivenxnataly/Hi-ResAudio).

It is the reason we knew where to look. Before finding it, "use the earpiece
as a second speaker on a MediaTek phone" was a vague idea with no entry point.
That module is what pointed at MediaTek's `2nd Loudspeaker` / `bes_loudness`
machinery and at the earpiece `<devicePort>` channel mask — and working out
why those particular levers *don't* pan out on the CMF Phone 1 is what led to
the routing that does. Reverse-engineering a vendor audio stack and giving the
result away for free is generous work, and this project started from it.
Thank you.

It also aims at a different goal — high-resolution output, not dual speakers —
so it is worth trying on its own terms if that is what you want.

### One bug worth reporting upstream

Tested against `v2.0 with aaudio_mmap`, versionCode 20000, commit `78706f5`
(2025-06-12). It bootlooped a CMF Phone 1, and the cause is a small typo with
large consequences. In `customize.sh`:

```sh
name="Apply Same Filter Setting with 2nd Loudspeaker\/>
```

The attribute value is never closed — `name="` opens a quote, then text, then
`/>`, with no closing `"`. The fix is one character:

```sh
name="Apply Same Filter Setting with 2nd Loudspeaker\"\/>
```

Without it, this reaches `Playback_ParamTreeView.xml`:

```xml
<Field ... name="Apply Same Filter Setting with 2nd Loudspeaker/>
```

MediaTek's AudioParamParser cannot parse that, so the audio HAL aborts on
every boot. The `sed` fires on any device carrying a `bes_loudness_L_lpf_order`
field.

Two other things to be aware of on a device like this one: it forces
`aaudio.mmap_policy=3` / `aaudio.mmap_exclusive_policy=3` plus
`killall audioserver`, which needs a HAL with an MMAP PCM path; and it sets
the speaker channel mask to `AUDIO_CHANNEL_OUT_SURROUND`, which not every
speaker port accepts.

And a correction to an earlier version of this file, which claimed its
`<mixPort>` insertions land mid-element: **they do not.** It computes the
correct insertion point (`POL + POLD - 1`, the last line of the
`primary output` block) and only writes when that matches a known constant,
so placement is self-consistent, and otherwise it skips. That claim was wrong
and is retracted.

### Why its stereo approach doesn't work on this device

Not a criticism of the approach — it is sound on hardware that has a second
loudspeaker. Two things stop it here:

- `Playback_ParamTreeView.xml` is the **view definition** for MediaTek's
  parameter tuning tool (`TreeRoot`, `Feature`, `FieldList`,
  `CategoryPathList`). The runtime coefficients live in
  `PlaybackACF_AudioParam.xml`. Editing the view changes which fields a tuning
  application displays, not what the DSP does.
- On the CMF Phone 1 every `bes_loudness_R_*` value and
  `bes_loudness_Sep_LR_Filter` read `0x0` — MediaTek's stock template,
  untuned, because this phone has no second loudspeaker. And 2nd-ACF is a
  *filter* feature: it applies a different EQ curve to a second transducer's
  channel, it does not create a route to one.

What this module took from it: edit the element you mean to change, validate
the result, and keep a way back. Hence the block-aware `awk`, the XML
structural check, and the boot watchdog.

Do not run both modules at the same time — they touch the same files.

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

Layout:

| path | what |
|---|---|
| `scripts/common.sh` | action engine, tinymix handling, guard, snapshots |
| `scripts/stereo-daemon.sh` | applies and re-asserts the routing |
| `scripts/stereoctl` | the CLI |
| `scripts/probe.sh` | hardware dump |
| `scripts/xml_patch.sh` | audio-policy overlay (opt-in, not for this device) |
| `config/actions.cmf1.conf` | the verified CMF Phone 1 routing |
| `bin/tinymix` | static aarch64 tinyalsa build, see `bin/README.md` |

---

## Credits and licence

The module scripts are free to use, modify and redistribute — attribution
welcome, not required.

`bin/tinymix` is a statically linked `aarch64` build of
[tinyalsa](https://github.com/tinyalsa/tinyalsa), BSD-3-Clause. Its licence,
upstream commit and exact build command are in
[`bin/README.md`](bin/README.md), so you can reproduce it rather than trust
the shipped binary.

Thanks to **Adinata ([@Adivenxnataly](https://github.com/adivenxnataly))**,
whose [Hi-Res Audio™](https://github.com/adivenxnataly/Hi-ResAudio) module
pointed this project at the right part of MediaTek's audio stack.

Thanks also to the people who worked out this mod on other hardware and wrote
it up —
[OnePlus 6](https://www.xda-developers.com/oneplus-6-stereo-speaker-mod/),
[Xiaomi Merlin](https://github.com/Charlie-117/merlin_DualSpeaker_mod),
[LeEco Le Max 2](https://github.com/J3is/Dual-Speaker-x2),
[whyred](https://xdaforums.com/t/magisk-dual-speaker-mod-for-whyred.3845595/).
They are also the reason "pseudo-stereo" is the honest label for this.

Built with [Claude Code](https://claude.com/claude-code) against a real
CMF Phone 1 — every routing claim here came from measurements on the device,
not from documentation.
