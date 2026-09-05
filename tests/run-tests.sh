#!/usr/bin/env sh
# Off-device checks for the parts that do not need Android: the action engine,
# the XML structural validator, and the speaker-port rewrite.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok   - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  FAIL - $1"; }
check(){ if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$3', got '$2')"; fi; }

export DATADIR="$TMP/data" MODDIR="$ROOT"
mkdir -p "$DATADIR/state"
. "$ROOT/scripts/common.sh"

echo "action engine"
# sysfs actions stand in for mixer controls: same save/apply/revert path.
mkdir -p "$TMP/sys"
echo 0 > "$TMP/sys/rcv_switch"
echo 3 > "$TMP/sys/rcv_gain"
cat > "$ACTIONS" <<CONF
# comment line, ignored
ctl|Nonexistent Control|1
sysfs|$TMP/sys/rcv_switch|1
sysfs|$TMP/sys/rcv_gain|7
sysfs|$TMP/sys/not_there|1
CONF
check "action_count skips comments and blanks" "$(action_count)" "4"
apply_actions
check "sysfs switch applied"   "$(cat "$TMP/sys/rcv_switch")" "1"
check "sysfs gain applied"     "$(cat "$TMP/sys/rcv_gain")"   "7"
check "original switch saved"  "$(_original sysfs "$TMP/sys/rcv_switch")" "0"
check "original gain saved"    "$(_original sysfs "$TMP/sys/rcv_gain")"   "3"

# A second apply must not overwrite the saved originals with our own values.
apply_actions
check "original survives re-apply" "$(_original sysfs "$TMP/sys/rcv_gain")" "3"

revert_actions
check "sysfs switch reverted" "$(cat "$TMP/sys/rcv_switch")" "0"
check "sysfs gain reverted"   "$(cat "$TMP/sys/rcv_gain")"   "3"

echo "kill switch"
check "armed by default" "$(module_active && echo yes || echo no)" "yes"
touch "$KILLSWITCH"
check "disarmed by killswitch" "$(module_active && echo yes || echo no)" "no"
rm -f "$KILLSWITCH"

echo "boot watchdog"
boot_strike_clear
boot_strike_add; boot_strike_add
check "strikes counted" "$(boot_strikes)" "2"
boot_strike_clear
check "strikes cleared" "$(boot_strikes)" "0"

echo "value normalisation"
mkdir -p "$TMP/bin"
export STUBLOG="$TMP/stub.log"
# Formats taken verbatim from tinymix on the CMF Phone 1.
check "enum -> selected entry" \
  "$(ctl_normalize 'Open, Mute, > Voice Playback, Test Mode,')" "Voice Playback"
check "enum, first entry selected" \
  "$(ctl_normalize '> Open, Mute, Voice Playback, Test Mode,')" "Open"
check "enum with underscores" \
  "$(ctl_normalize 'Disable, > Enable,')" "Enable"
# The range suffix contains "->", which must not be mistaken for an enum marker.
check "int -> bare number" "$(ctl_normalize '31 (range 0->18)')" "31"
check "int, zero"          "$(ctl_normalize '0 (range 0->65535)')" "0"
check "int, negative"      "$(ctl_normalize '-1 (range -2147483648->0)')" "-1"
check "bool On -> 1"       "$(ctl_normalize 'On')"  "1"
check "bool Off -> 0"      "$(ctl_normalize 'Off')" "0"
check "plain value passes through" "$(ctl_normalize '42')" "42"

# Round trip: what ctl_get returns must be accepted by ctl_set.
: > "$STUBLOG"
cat > "$TMP/bin/tinymix-fmt" <<'STUB'
#!/bin/sh
case "$1" in
  --help|-h) printf 'commands:\n\tget NAME|ID : x\n\tset NAME|ID VALUE : x\n'; exit 0 ;;
  get)
    case "$2" in
      'RCV Mux')                  echo 'Open, Mute, > Voice Playback, Test Mode,' ;;
      'Handset Volume')           echo '31 (range 0->18)' ;;
      'ADDA_DL_CH1 DL_24CH_CH1')  echo 'Off' ;;
      # Real tinymix errors out on an unknown control rather than
      # answering with a value.
      *) echo 'Invalid mixer control' >&2; exit 1 ;;
    esac
    exit 0 ;;
  set) echo "CALLED:set:$2:$3" >> "$STUBLOG"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$TMP/bin/tinymix-fmt"
TINYMIX="$TMP/bin/tinymix-fmt"; unset TINYMIX_STYLE; MIXER_CARD=
check "enum round trip"  "$(ctl_get 'RCV Mux')" "Voice Playback"
check "int round trip"   "$(ctl_get 'Handset Volume')" "31"
check "bool round trip"  "$(ctl_get 'ADDA_DL_CH1 DL_24CH_CH1')" "0"
ctl_set 'RCV Mux' "$(ctl_get 'RCV Mux')"
check "revert sets a bare enum name" \
  "$(grep -c '^CALLED:set:RCV Mux:Voice Playback$' "$STUBLOG")" "1"
ctl_set 'Handset Volume' "$(ctl_get 'Handset Volume')"
check "revert sets a bare integer" \
  "$(grep -c '^CALLED:set:Handset Volume:31$' "$STUBLOG")" "1"
unset TINYMIX TINYMIX_STYLE

echo "guard control"
TINYMIX="$TMP/bin/tinymix-fmt"; unset TINYMIX_STYLE
GUARD_CTL=; GUARD_VALUE=
check "no guard configured -> always ok" "$(guard_ok && echo yes || echo no)" "yes"
GUARD_CTL='RCV Mux'; GUARD_VALUE='Voice Playback'
check "guard matches -> ok"      "$(guard_ok && echo yes || echo no)" "yes"
GUARD_VALUE='Open'
check "guard differs -> blocked" "$(guard_ok && echo yes || echo no)" "no"
GUARD_CTL='No Such Control'; GUARD_VALUE='Enable'
check "missing guard control does not block" "$(guard_ok && echo yes || echo no)" "yes"
GUARD_CTL=; GUARD_VALUE=; unset TINYMIX TINYMIX_STYLE

echo "mixer snapshot diff"
cat > "$TMP/snap.a" <<'SNAP'
664	BOOL	1	Ext_Speaker_Amp Switch	Off
670	ENUM	1	HPL Mux	>Open, Audio Playback,
672	ENUM	1	RCV Mux	>Open, Voice Playback,
560	INT	1	Handset Volume	4
SNAP
cat > "$TMP/snap.b" <<'SNAP'
664	BOOL	1	Ext_Speaker_Amp Switch	On
670	ENUM	1	HPL Mux	>Open, Audio Playback,
672	ENUM	1	RCV Mux	Open, >Voice Playback,
560	INT	1	Handset Volume	4
SNAP
OUT=$(diff_snapshots "$TMP/snap.a" "$TMP/snap.b")
check "reports the changed switch"  "$(echo "$OUT" | grep -c 'Ext_Speaker_Amp Switch')" "2"
check "reports the changed mux"     "$(echo "$OUT" | grep -c 'RCV Mux')" "2"
check "ignores unchanged controls"  "$(echo "$OUT" | grep -c 'Handset Volume')" "0"
check "ignores unchanged mux"       "$(echo "$OUT" | grep -c 'HPL Mux')" "0"
OUT=$(diff_snapshots "$TMP/snap.a" "$TMP/snap.a")
check "identical snapshots are quiet" "$(echo "$OUT" | grep -c 'no control changed')" "1"

echo "portability lint"
# Android's grep is toybox: it treats \| in a basic regex as a literal, so
# every pattern written that way matches nothing and reports it as a clean
# zero. This cost a full probe cycle - three "0 hits" summary lines that were
# the greps failing, not the hardware missing. Alternation must use -E.
BRE=$(grep -n 'grep' "$ROOT"/scripts/* "$ROOT"/customize.sh "$ROOT"/service.sh \
        "$ROOT"/post-fs-data.sh "$ROOT"/uninstall.sh 2>/dev/null \
        | grep -c '\\|' )
check "no BRE alternation in any grep" "$BRE" "0"

echo "tinymix CLI detection"
# Stubs standing in for the two calling conventions. The new-style help text
# is copied from tinyalsa 2.x (tab-indented, which is what made the first
# detection attempt fail); the old one from tinyalsa 1.x.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/tinymix-new" <<'STUB'
#!/bin/sh
case "$1" in
  --help|-h)
    printf 'usage: tinymix [options] <command>\noptions:\n\t-h, --help : help\ncommands:\n\tget NAME|ID              : prints the values of a control\n\tset NAME|ID VALUE(S) ... : sets the value of a control\n'
    exit 0 ;;
  get)
    [ -z "${2:-}" ] && { echo "no control specified" >&2; exit 1; }
    echo "CALLED:get:$2" >> "$STUBLOG"; echo 7; exit 0 ;;
  set)
    echo "CALLED:set:$2:$3" >> "$STUBLOG"; exit 0 ;;
esac
exit 1
STUB
cat > "$TMP/bin/tinymix-old" <<'STUB'
#!/bin/sh
case "$1" in
  --help|-h) echo "Usage: tinymix [-D card] [-a] [ctrl id/name [value(s)]]"; exit 0 ;;
esac
if [ $# -eq 2 ]; then echo "CALLED:set:$1:$2" >> "$STUBLOG"; exit 0; fi
if [ $# -eq 1 ]; then echo "CALLED:get:$1" >> "$STUBLOG"; echo "Mixer name: stub"; echo 7; exit 0; fi
exit 1
STUB
chmod +x "$TMP/bin/tinymix-new" "$TMP/bin/tinymix-old"

TINYMIX="$TMP/bin/tinymix-new"; unset TINYMIX_STYLE
check "tinyalsa 2.x detected as new" "$(tinymix_style)" "new"
TINYMIX="$TMP/bin/tinymix-old"; unset TINYMIX_STYLE
check "tinyalsa 1.x detected as old" "$(tinymix_style)" "old"

# The style must translate into the right argv, or writes silently do nothing.
: > "$STUBLOG"
TINYMIX="$TMP/bin/tinymix-new"; unset TINYMIX_STYLE; MIXER_CARD=
check "new-style get value" "$(ctl_get 'Receiver Switch')" "7"
ctl_set 'Receiver Switch' 1
check "new-style set argv" "$(grep -c '^CALLED:set:Receiver Switch:1$' "$STUBLOG")" "1"

: > "$STUBLOG"
TINYMIX="$TMP/bin/tinymix-old"; unset TINYMIX_STYLE
check "old-style get strips header" "$(ctl_get 'Receiver Switch')" "7"
ctl_set 'Receiver Switch' 1
check "old-style set argv" "$(grep -c '^CALLED:set:Receiver Switch:1$' "$STUBLOG")" "1"
# A binary that cannot execute at all (wrong arch) must not be mistaken for
# the 1.x CLI - that would make every write a silent no-op.
cat > "$TMP/bin/tinymix-broken" <<'STUB'
#!/bin/sh
exit 126
STUB
chmod +x "$TMP/bin/tinymix-broken"
TINYMIX="$TMP/bin/tinymix-broken"; unset TINYMIX_STYLE
check "unrunnable binary reported unknown" "$(tinymix_style)" "unknown"
unset TINYMIX_STYLE
ctl_set 'Receiver Switch' 1 2>/dev/null
check "unknown style refuses to write" "$?" "1"
unset TINYMIX TINYMIX_STYLE

echo "xml validation"
cat > "$TMP/good.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<audioPolicyConfiguration version="7.0">
  <modules>
    <module name="primary" halVersion="3.0">
      <mixPorts>
        <mixPort name="primary output" role="source" flags="AUDIO_OUTPUT_FLAG_PRIMARY">
          <profile name="" format="AUDIO_FORMAT_PCM_16_BIT" samplingRates="44100 48000" channelMasks="AUDIO_CHANNEL_OUT_STEREO"/>
        </mixPort>
      </mixPorts>
      <devicePorts>
        <devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink">
          <profile name="" format="AUDIO_FORMAT_PCM_16_BIT" samplingRates="44100 48000" channelMasks="AUDIO_CHANNEL_OUT_MONO"/>
        </devicePort>
        <devicePort tagName="Earpiece" type="AUDIO_DEVICE_OUT_EARPIECE" role="sink">
          <profile name="" format="AUDIO_FORMAT_PCM_16_BIT" samplingRates="44100 48000" channelMasks="AUDIO_CHANNEL_OUT_MONO"/>
        </devicePort>
      </devicePorts>
      <routes>
        <route type="mix" sink="Speaker" sources="primary output"/>
      </routes>
    </module>
  </modules>
</audioPolicyConfiguration>
XML
xml_sane "$TMP/good.xml" >/dev/null 2>&1
check "well-formed policy accepted" "$?" "0"

# The exact failure the Hi-Res module produces: a mixPort inserted at a
# hardcoded line number, landing inside another element and never closed.
sed '7i\        <mixPort name="mmap_no_irq_out" role="source">' "$TMP/good.xml" > "$TMP/bad.xml"
xml_sane "$TMP/bad.xml" >/dev/null 2>&1
check "unbalanced mixPort rejected" "$?" "1"

head -n 12 "$TMP/good.xml" > "$TMP/trunc.xml"
xml_sane "$TMP/trunc.xml" >/dev/null 2>&1
check "truncated policy rejected" "$?" "1"

echo "speaker port rewrite"
# Reuse the real patch_one from xml_patch.sh rather than a copy of the awk.
XML_PATCH_LIB=1 . "$ROOT/scripts/xml_patch.sh"
patch_one "$TMP/good.xml" "$TMP/patched.xml"
check "patch_one succeeded" "$?" "0"
check "speaker port widened to stereo" \
  "$(sed -n '/tagName="Speaker"/,/<\/devicePort>/p' "$TMP/patched.xml" | grep -c AUDIO_CHANNEL_OUT_STEREO)" "1"
check "earpiece port left alone" \
  "$(sed -n '/tagName="Earpiece"/,/<\/devicePort>/p' "$TMP/patched.xml" | grep -c AUDIO_CHANNEL_OUT_MONO)" "1"
check "devicePorts container preserved" \
  "$(grep -c '<devicePorts>' "$TMP/patched.xml")" "1"
check "mixPort left alone" "$(grep -c 'name="primary output"' "$TMP/patched.xml")" "1"
xml_sane "$TMP/patched.xml" >/dev/null 2>&1
check "patched policy still valid" "$?" "0"
check "line count unchanged" \
  "$(wc -l < "$TMP/patched.xml")" "$(wc -l < "$TMP/good.xml")"

# A speaker port written as a single self-closing element must also work.
cat > "$TMP/selfclose.xml" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<audioPolicyConfiguration version="7.0">
  <modules>
    <module name="primary" halVersion="3.0">
      <devicePorts>
        <devicePort tagName="Speaker" type="AUDIO_DEVICE_OUT_SPEAKER" role="sink" channelMasks="AUDIO_CHANNEL_OUT_MONO"/>
        <devicePort tagName="Earpiece" type="AUDIO_DEVICE_OUT_EARPIECE" role="sink" channelMasks="AUDIO_CHANNEL_OUT_MONO"/>
      </devicePorts>
    </module>
  </modules>
</audioPolicyConfiguration>
XML
patch_one "$TMP/selfclose.xml" "$TMP/selfclose-out.xml"
check "self-closing speaker port patched" "$?" "0"
check "self-closing speaker now stereo" \
  "$(grep -c 'tagName="Speaker".*AUDIO_CHANNEL_OUT_STEREO' "$TMP/selfclose-out.xml")" "1"
check "self-closing earpiece untouched" \
  "$(grep -c 'tagName="Earpiece".*AUDIO_CHANNEL_OUT_MONO' "$TMP/selfclose-out.xml")" "1"
check "self-closing line count unchanged" \
  "$(wc -l < "$TMP/selfclose-out.xml")" "$(wc -l < "$TMP/selfclose.xml")"

# A policy with no speaker devicePort must be refused, not silently copied.
grep -v 'AUDIO_DEVICE_OUT_SPEAKER' "$TMP/good.xml" > "$TMP/nospk.xml"
patch_one "$TMP/nospk.xml" "$TMP/nospk-out.xml" 2>/dev/null
check "no speaker port -> refused" "$?" "3"
check "no output file left behind" "$([ -f "$TMP/nospk-out.xml" ] && echo yes || echo no)" "no"

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ]
