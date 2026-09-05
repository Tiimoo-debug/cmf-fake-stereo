# CMF Phone 1 — stereo speaker module

Drives the earpiece as a second speaker so the CMF Phone 1 plays real stereo
instead of mono out of the bottom firing driver.

**Status: phase 1 — probe.** Installing this changes nothing about how the
phone sounds. It ships the tooling to find out how this specific device routes
its earpiece, plus the engine that will apply that routing once it is known.
`actions.conf` is empty on purpose; see [Why it ships empty](#why-it-ships-empty).

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

**3. MediaTek "2nd loudspeaker".** MTK's audio DSP has a native concept of a
second output transducer: `bes_loudness_Sep_LR_Filter` ("Apply Same Filter
Setting with 2nd Loudspeaker"), `2nd Loudspeaker Compensation Filter
(2nd-ACF)`, separate L/R high- and low-pass filter orders. If the CMF Phone 1
ships those in its AudioParam tree, the hardware path for stereo already
exists and mostly needs enabling rather than inventing. The probe captures
this whole tree — it is the most promising lead.

---

## Commands

```
stereoctl status              module, daemon, and live control values
stereoctl probe [dir]         dump the audio hardware
stereoctl on | off            arm / disarm, no reboot
stereoctl apply | revert      one-shot apply / restore
stereoctl restart             restart the watcher daemon
stereoctl log [n]             tail the log

stereoctl scan [pattern]      search the mixer for candidate controls
stereoctl ctl NAME [VALUE]    read or write one mixer control
stereoctl dump                every control and its value

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

---

## Why it ships empty

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

## If the probe says NO TINYMIX FOUND

Mixer controls cannot be read or written without a `tinymix` binary, and not
every vendor ships one. Any of these fixes it:

- Termux: `pkg install tinyalsa` (then `cp $PREFIX/bin/tinymix /data/adb/cmf-stereo/bin/`)
- any Magisk "tinytools" / tinyalsa module
- an `arm64` `tinymix` built from AOSP `external/tinyalsa`, pushed to
  `/data/adb/cmf-stereo/bin/tinymix` and `chmod 0755`

The module looks in `/data/adb/cmf-stereo/bin`, the module's own `bin/`,
`/vendor/bin`, `/system/bin`, `/odm/bin`, `/data/local/tmp` and `$PATH`.
Both the old `tinymix NAME VALUE` and the tinyalsa 2.x
`tinymix set NAME VALUE` calling conventions are handled.

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
