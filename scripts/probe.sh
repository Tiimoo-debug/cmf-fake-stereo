#!/system/bin/sh
# Hardware probe: collect everything needed to work out whether the earpiece
# can be co-driven with the main speaker, and under which control names.
#
# Writes a directory + tarball under /sdcard/cmf-stereo-probe-<timestamp>/.
# Nothing here modifies the device.

MODDIR=${MODDIR:-/data/adb/modules/cmf_stereo}

# Works both as part of the installed module and as a lone script pushed to
# /data/local/tmp, so it can be run before anything is flashed.
if [ -f "$MODDIR/scripts/common.sh" ]; then
  . "$MODDIR/scripts/common.sh"
elif [ -f "$(dirname "$0")/common.sh" ]; then
  . "$(dirname "$0")/common.sh"
else
  find_tinymix() {
    for _c in /vendor/bin/tinymix /system/bin/tinymix /system/vendor/bin/tinymix \
              /odm/bin/tinymix /data/local/tmp/tinymix; do
      [ -x "$_c" ] && { TINYMIX=$_c; return 0; }
    done
    _c=$(command -v tinymix 2>/dev/null)
    [ -n "$_c" ] && { TINYMIX=$_c; return 0; }
    return 1
  }
  tinymix_style() {
    if "$TINYMIX" get 2>&1 | grep -qi 'usage\|no such\|invalid'; then echo new
    elif "$TINYMIX" --help 2>&1 | grep -q ' get '; then echo new
    else echo old; fi
  }
fi

OUT_BASE=${1:-/sdcard}
STAMP=$(date '+%Y%m%d-%H%M%S')
OUT=$OUT_BASE/cmf-stereo-probe-$STAMP
mkdir -p "$OUT" || { echo "cannot write to $OUT_BASE"; exit 1; }

say() { echo "$@"; }
sec() { echo; echo "===== $* ====="; }

##############################################################################
say "Probing audio hardware -> $OUT"

##############################################################################
# 1. device identity
##############################################################################
{
  sec "build"
  for p in ro.product.model ro.product.device ro.product.name ro.product.board \
           ro.board.platform ro.hardware ro.build.version.release \
           ro.build.version.sdk ro.build.version.security_patch \
           ro.build.display.id ro.vendor.build.fingerprint; do
    echo "$p=$(getprop $p)"
  done
  sec "audio-related properties"
  getprop | grep -i 'audio\|sound\|speaker\|codec\|smartpa\|\bpa\b' 
} > "$OUT/00-device.txt" 2>&1
say "  [1/11] device identity"

##############################################################################
# 2. ALSA topology
##############################################################################
{
  sec "/proc/asound/cards";   cat /proc/asound/cards 2>&1
  sec "/proc/asound/devices"; cat /proc/asound/devices 2>&1
  sec "/proc/asound/pcm";     cat /proc/asound/pcm 2>&1
  sec "tree";                 ls -lR /proc/asound/ 2>&1
  for f in /proc/asound/card*/pcm*/sub*/hw_params /proc/asound/card*/pcm*/sub*/status; do
    [ -f "$f" ] && { sec "$f"; cat "$f" 2>&1; }
  done
} > "$OUT/01-alsa.txt" 2>&1
say "  [2/11] ALSA topology"

##############################################################################
# 3. mixer controls - the important one
##############################################################################
{
  if find_tinymix; then
    sec "tinymix binary"; echo "$TINYMIX"; echo "style=$(tinymix_style)"
    sec "tinymix controls"
    if [ "$(tinymix_style)" = new ]; then
      "$TINYMIX" controls 2>&1
      sec "tinymix contents"
      "$TINYMIX" contents 2>&1
    else
      "$TINYMIX" 2>&1
    fi
  else
    echo "NO TINYMIX FOUND."
    echo
    echo "Mixer controls cannot be listed or set without it. See the module"
    echo "README, section 'If the probe says NO TINYMIX FOUND'."
  fi
} > "$OUT/02-mixer.txt" 2>&1
say "  [3/11] mixer controls"

##############################################################################
# 4. candidate controls - what a receiver/earpiece path tends to be called
##############################################################################
{
  if [ -s "$OUT/02-mixer.txt" ]; then
    sec "lines matching receiver / earpiece / handset"
    grep -in 'receiver\|earpiece\|rcv\|handset\|ear_\|_ear' "$OUT/02-mixer.txt"
    sec "lines matching speaker / spk / smart PA"
    grep -in 'speaker\|spk\|smartpa\|aw8\|tfa\|cs35\|sipa\|fs16\|awinic' "$OUT/02-mixer.txt"
    sec "lines matching output stage / DAC / amp / gain"
    grep -in 'lineout\|dac\|amp\|pga\|gain\|volume\|hp ' "$OUT/02-mixer.txt"
    sec "lines matching mixer routing (DLx / UL / I2S / TDM)"
    grep -in 'dl1\|dl2\|dl3\|dl_\|i2s\|tdm\|adda\|hostless' "$OUT/02-mixer.txt"
  fi
} > "$OUT/03-candidates.txt" 2>&1
say "  [4/11] candidate controls"

##############################################################################
# 5. smart amplifier drivers
##############################################################################
{
  sec "sysfs class entries"
  for d in /sys/class/*; do
    case $(basename "$d") in
      *aw88*|*aw87*|*awinic*|*tfa*|*cs35*|*sipa*|*fs16*|*smartpa*|*audio*|*sound*|*speaker*)
        echo "--- $d"; ls -l "$d" 2>&1 ;;
    esac
  done
  sec "matching sysfs device nodes"
  find /sys/devices -maxdepth 6 \( -iname '*aw88*' -o -iname '*tfa*' -o -iname '*smartpa*' \
       -o -iname '*cs35*' -o -iname '*sipa*' -o -iname '*fs16*' \) 2>/dev/null | head -n 60
  sec "i2c device names"
  for f in /sys/bus/i2c/devices/*/name; do
    [ -f "$f" ] && echo "$f = $(cat "$f" 2>/dev/null)"
  done
  sec "loaded modules"; lsmod 2>&1 | head -n 80
  sec "codec-related kernel log"
  (dmesg 2>/dev/null || cat /proc/kmsg 2>/dev/null) \
    | grep -i 'codec\|asoc\|snd\|smartpa\|aw88\|tfa\|speaker\|receiver\|mt6\(3\|8\)' \
    | tail -n 200
} > "$OUT/04-amplifier.txt" 2>&1
say "  [5/11] amplifier drivers"

##############################################################################
# 6. audio HAL configuration files
##############################################################################
mkdir -p "$OUT/05-hal-configs"
{
  sec "config files found"
  for dir in /vendor/etc /vendor/etc/audio /odm/etc /odm/etc/audio /system/etc \
             /vendor/etc/audio_param /vendor/etc/audiocustom; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 2 \( -name 'audio*' -o -name 'mixer_paths*' -o -name '*acdb*' \) 2>/dev/null
  done
} > "$OUT/05-hal-configs/index.txt" 2>&1
for dir in /vendor/etc /vendor/etc/audio /odm/etc /odm/etc/audio; do
  [ -d "$dir" ] || continue
  for f in $(find "$dir" -maxdepth 2 \( -name 'audio_policy_configuration*.xml' \
             -o -name 'audio_device*.xml' -o -name 'mixer_paths*.xml' \
             -o -name 'audio_effects*' -o -name 'audio_platform*' \) 2>/dev/null); do
    cp -f "$f" "$OUT/05-hal-configs/$(echo "${f#/}" | tr '/' '_')" 2>/dev/null
  done
done
say "  [6/11] HAL config files"

##############################################################################
# 7. the Speaker device port - does the policy already declare stereo?
##############################################################################
{
  for f in "$OUT/05-hal-configs"/*audio_policy_configuration*.xml; do
    [ -f "$f" ] || continue
    sec "$f : Speaker devicePort"
    awk '/<devicePort/ { block = $0; inblk = 1 }
         inblk && !/<devicePort/ { block = block "\n" $0 }
         inblk && /<\/devicePort>/ {
           if (block ~ /AUDIO_DEVICE_OUT_SPEAKER|AUDIO_DEVICE_OUT_EARPIECE/) print block "\n"
           inblk = 0
         }' "$f"
  done
} > "$OUT/06-speaker-port.txt" 2>&1
say "  [7/11] speaker device port"

##############################################################################
# 8. HAL binaries and effects - tells us which HAL implementation is in play
##############################################################################
{
  sec "audio HAL libraries"
  ls -l /vendor/lib*/hw/audio.* /vendor/lib*/hw/android.hardware.audio* 2>&1
  sec "audio HAL services"
  ls -l /vendor/bin/hw/ 2>/dev/null | grep -i audio
  sec "running audio processes"
  ps -A 2>/dev/null | grep -i 'audio\|media' | grep -v grep
  sec "soundfx"
  ls -l /vendor/lib*/soundfx/ /system/lib*/soundfx/ 2>&1
  sec "audio HAL manifest entries"
  grep -i -A3 'audio' /vendor/etc/vintf/manifest.xml 2>/dev/null | head -n 60
} > "$OUT/07-hal.txt" 2>&1
say "  [8/11] HAL implementation"

##############################################################################
# 9. current audio routing state
##############################################################################
{
  sec "dumpsys audio (head)"
  dumpsys audio 2>/dev/null | head -n 250
  sec "dumpsys media.audio_flinger (head)"
  dumpsys media.audio_flinger 2>/dev/null | head -n 250
} > "$OUT/08-routing.txt" 2>&1
say "  [9/11] current routing"

##############################################################################
# 10. MediaTek AudioParam tree - where a 2nd loudspeaker is declared
#
# MTK's HAL has a "2nd Loudspeaker" concept (bes_loudness ACF, Sep_LR filter).
# If this device's param tree carries it, the DSP already knows how to drive a
# second output transducer, which is the most promising route to real stereo.
##############################################################################
mkdir -p "$OUT/09-audio-param"
for dir in /vendor/etc/audio_param /odm/etc/audio_param /vendor/etc/audiocustom \
           /vendor/etc/audio /odm/etc/audio; do
  [ -d "$dir" ] || continue
  find "$dir" -type f -name '*.xml' -size -2048k 2>/dev/null | while read -r f; do
    cp -f "$f" "$OUT/09-audio-param/$(echo "${f#/}" | tr '/' '_')" 2>/dev/null
  done
done
{
  sec "param directories present"
  for dir in /vendor/etc/audio_param /odm/etc/audio_param /vendor/etc/audiocustom; do
    [ -d "$dir" ] && ls -l "$dir" 2>&1
  done
  sec "2nd loudspeaker / bes_loudness / ACF hits across vendor configs"
  grep -ril 'bes_loudness\|2nd Loudspeaker\|Sep_LR\|SecondSpk\|2nd-ACF\|spk2\|Speaker2' \
    /vendor/etc /odm/etc 2>/dev/null | head -n 40
  sec "matching lines"
  grep -rih 'bes_loudness_Sep_LR\|2nd Loudspeaker\|2nd-ACF\|SecondSpk\|Speaker2\|spk2' \
    /vendor/etc /odm/etc 2>/dev/null | head -n 120
  sec "legacy audio_policy.conf"
  for f in /vendor/etc/audio_policy.conf /system/etc/audio_policy.conf /odm/etc/audio_policy.conf; do
    [ -f "$f" ] && { echo "--- $f"; cat "$f"; }
  done
  sec "aaudio / mmap properties (context for the Hi-Res module)"
  getprop | grep -i 'aaudio\|mmap'
} > "$OUT/09-audio-param/index.txt" 2>&1
say "  [10/11] MediaTek AudioParam tree"

##############################################################################
# 11. safety baseline - current earpiece/receiver gain settings
##############################################################################
{
  sec "receiver / earpiece gain-ish mixer controls and their current values"
  if [ -s "$OUT/02-mixer.txt" ]; then
    grep -in 'receiver\|earpiece\|rcv\|handset\|voice' "$OUT/02-mixer.txt" \
      | grep -i 'volume\|gain\|pga\|db' | head -n 40
  fi
  sec "audio thermal / protection nodes"
  find /sys -maxdepth 6 \( -iname '*spk*prot*' -o -iname '*temp*cal*' -o -iname '*calib*' \) \
       -path '*aud*' 2>/dev/null | head -n 30
} > "$OUT/10-safety.txt" 2>&1
say "  [11/11] safety baseline"

##############################################################################
# summary + package
##############################################################################
{
  echo "CMF stereo probe - $STAMP"
  echo "model:      $(getprop ro.product.model)"
  echo "device:     $(getprop ro.product.device)"
  echo "platform:   $(getprop ro.board.platform)"
  echo "android:    $(getprop ro.build.version.release) (sdk $(getprop ro.build.version.sdk))"
  echo "build:      $(getprop ro.build.display.id)"
  echo
  if find_tinymix; then
    echo "tinymix:    $TINYMIX ($(tinymix_style) style)"
    echo "controls:   $(grep -c . "$OUT/02-mixer.txt" 2>/dev/null) lines captured"
  else
    echo "tinymix:    NOT FOUND  <-- blocks mixer control; see README"
  fi
  echo "receiver-ish control lines: $(grep -ic 'receiver\|earpiece\|rcv\|handset' "$OUT/02-mixer.txt" 2>/dev/null)"
  echo "smart PA hits:              $(grep -ic 'aw88\|tfa\|cs35\|sipa\|fs16\|smartpa' "$OUT/04-amplifier.txt" 2>/dev/null)"
  echo "2nd-loudspeaker hits:       $(grep -ic 'bes_loudness\|2nd Loudspeaker\|Sep_LR' "$OUT/09-audio-param/index.txt" 2>/dev/null)"
  echo "param XMLs captured:        $(ls -1 "$OUT/09-audio-param" 2>/dev/null | wc -l)"
  echo
  echo "Files:"
  ls -1 "$OUT"
} > "$OUT/SUMMARY.txt" 2>&1

chmod -R 0644 "$OUT" 2>/dev/null
find "$OUT" -type d -exec chmod 0755 {} \; 2>/dev/null

TARBALL=$OUT_BASE/cmf-stereo-probe-$STAMP.tar.gz
if tar -czf "$TARBALL" -C "$OUT_BASE" "cmf-stereo-probe-$STAMP" 2>/dev/null; then
  chmod 0644 "$TARBALL" 2>/dev/null
  say ""
  say "Done. Report: $OUT"
  say "      Tarball: $TARBALL"
else
  say ""
  say "Done. Report: $OUT  (tar unavailable, directory only)"
fi
say ""
cat "$OUT/SUMMARY.txt"
