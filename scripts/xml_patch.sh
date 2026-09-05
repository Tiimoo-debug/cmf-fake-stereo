#!/system/bin/sh
# Optional, opt-in: widen the Speaker output device from mono to stereo in the
# audio policy, by overlaying a patched copy of the vendor XML.
#
# This alone does NOT create stereo. It only stops the framework from
# downmixing to one channel before the HAL sees the audio, which is a
# prerequisite on devices whose policy declares Speaker as MONO. The actual
# left/right split still comes from the mixer actions.
#
# Everything is written into the module's overlay directory and only takes
# effect on the next boot, so it is fully reversible by disabling the module.

MODDIR=${MODDIR:-/data/adb/modules/cmf_stereo}
. "$MODDIR/scripts/common.sh"

OVERLAY_ROOT=$MODDIR/system

overlay_path_for() {
  # /vendor/etc/foo.xml -> $OVERLAY_ROOT/vendor/etc/foo.xml
  case $1 in
    /vendor/*)     echo "$OVERLAY_ROOT/vendor/${1#/vendor/}" ;;
    /odm/*)        echo "$OVERLAY_ROOT/odm/${1#/odm/}" ;;
    /product/*)    echo "$OVERLAY_ROOT/product/${1#/product/}" ;;
    /system_ext/*) echo "$OVERLAY_ROOT/system_ext/${1#/system_ext/}" ;;
    /system/*)     echo "$OVERLAY_ROOT/${1#/system/}" ;;
    *)             return 1 ;;
  esac
}

find_policy_files() {
  for dir in /vendor/etc /vendor/etc/audio /odm/etc /odm/etc/audio; do
    [ -d "$dir" ] || continue
    find "$dir" -maxdepth 2 -name 'audio_policy_configuration*.xml' 2>/dev/null
  done
}

# Rewrite AUDIO_CHANNEL_OUT_MONO -> ..._STEREO, but only inside the
# <devicePort> block for the speaker. Everything else is left byte-identical.
patch_one() {
  _src=$1
  _dst=$2
  mkdir -p "$(dirname "$_dst")" || return 1
  awk '
    function flush() {
      if (spk) { gsub(/AUDIO_CHANNEL_OUT_MONO/, "AUDIO_CHANNEL_OUT_STEREO", buf); changed++ }
      printf "%s", buf
      inblk = 0; buf = ""; spk = 0; selfclose = 0
    }
    # Match <devicePort> but never the <devicePorts> container: dropping that
    # one line yields a policy that still looks balanced but will not parse.
    /<devicePort[ \t>]/ && !inblk {
      inblk = 1; buf = ""; spk = 0
      selfclose = ($0 ~ /\/>[ \t]*$/)
    }
    inblk {
      if ($0 ~ /AUDIO_DEVICE_OUT_SPEAKER/) spk = 1
      buf = buf $0 "\n"
      if ($0 ~ /<\/devicePort>/ || (selfclose && buf ~ /\/>\n$/)) flush()
      next
    }
    { print }
    END { if (changed == 0) exit 3 }
  ' "$_src" > "$_dst"
  _rc=$?
  if [ $_rc -ne 0 ]; then
    rm -f "$_dst"
    return $_rc
  fi
  # A self-closing <devicePort .../> speaker entry never reaches the block
  # branch above; catch the no-op case so we do not ship an identical file.
  if cmp -s "$_src" "$_dst"; then
    rm -f "$_dst"
    return 4
  fi
  # Never let a structurally broken policy reach the overlay.
  _why=$(xml_sane "$_dst")
  if [ $? -ne 0 ]; then
    echo "  rejected patched copy of $_src: $_why"
    rm -f "$_dst"
    return 5
  fi
  chmod 0644 "$_dst"
  chown 0:0 "$_dst" 2>/dev/null
  chcon u:object_r:vendor_configs_file:s0 "$_dst" 2>/dev/null
  return 0
}

cmd_patch() {
  _any=0
  for f in $(find_policy_files); do
    _dst=$(overlay_path_for "$f") || { echo "  skip (unmappable path): $f"; continue; }
    if grep -q 'AUDIO_CHANNEL_OUT_STEREO' "$f" && ! grep -q 'AUDIO_CHANNEL_OUT_MONO' "$f"; then
      echo "  skip (already stereo): $f"
      continue
    fi
    patch_one "$f" "$_dst"
    case $? in
      0) echo "  patched: $f"; _any=1 ;;
      3) echo "  skip (no speaker devicePort found): $f" ;;
      4) echo "  skip (speaker port is not mono): $f" ;;
      5) ;;  # patch_one already explained the rejection
      *) echo "  FAILED:  $f" ;;
    esac
  done
  if [ $_any -eq 1 ]; then
    echo
    echo "Overlay written under $OVERLAY_ROOT."
    echo "Reboot to apply. If audio breaks, disable the module in your root"
    echo "manager and reboot, or run: stereoctl xml-revert"
  else
    echo
    echo "Nothing patched - the policy does not declare a mono speaker port,"
    echo "so this step is not what is holding stereo back on this device."
  fi
}

cmd_revert() {
  _n=0
  for d in "$OVERLAY_ROOT/vendor/etc" "$OVERLAY_ROOT/odm/etc" \
           "$OVERLAY_ROOT/vendor/etc/audio" "$OVERLAY_ROOT/odm/etc/audio"; do
    [ -d "$d" ] || continue
    for f in "$d"/audio_policy_configuration*.xml; do
      [ -f "$f" ] && { rm -f "$f"; echo "  removed: $f"; _n=$((_n + 1)); }
    done
  done
  # Prune the directories we created, leaving anything else alone.
  find "$OVERLAY_ROOT" -type d -empty -delete 2>/dev/null
  [ $_n -eq 0 ] && echo "  nothing to revert" || echo "Reboot to restore the stock policy."
}

# Sourced by the test suite to reuse patch_one without running anything.
[ "${XML_PATCH_LIB:-0}" = 1 ] && return 0

case ${1:-patch} in
  patch)  cmd_patch ;;
  revert) cmd_revert ;;
  *)      echo "usage: xml_patch.sh [patch|revert]"; exit 1 ;;
esac
