#!/system/bin/sh
# Installer. Deliberately does nothing to the audio stack: it lays down the
# tooling and the config, and tells you what to run next.

SKIPMOUNT=false
PROPFILE=false
POSTFSDATA=true
LATESTARTSERVICE=true

DATADIR=/data/adb/cmf-stereo

ui_print " "
ui_print "  CMF Phone 1 - stereo speaker"
ui_print "  ----------------------------"
ui_print "  device   : $(getprop ro.product.model) ($(getprop ro.product.device))"
ui_print "  platform : $(getprop ro.board.platform) / $(getprop ro.soc.manufacturer)"
ui_print "  android  : $(getprop ro.build.version.release) (API $API)"
ui_print " "

if [ "$API" -lt 31 ]; then
  ui_print "  ! Android 12 or newer expected; continuing anyway."
fi

IS_CMF1=0
case "$(getprop ro.product.device)$(getprop ro.product.model)" in
  *[Tt]etris*|*A015*|*CMF*|*cmf*) IS_CMF1=1 ;;
  *)
    ui_print "  ! This does not look like a CMF Phone 1."
    ui_print "    Nothing is applied automatically, so it is safe to keep"
    ui_print "    going - the probe works on any device."
    ui_print " "
    ;;
esac

##############################################################################
# config in /data so it survives module updates
##############################################################################
mkdir -p "$DATADIR/state" "$DATADIR/bin"

if [ -f "$DATADIR/stereo.conf" ]; then
  # Keep the user's settings, but add keys introduced by newer versions -
  # otherwise an upgrade silently runs without them.
  ADDED=0
  for KEY in ENABLED MODE WATCH_INTERVAL STARTUP_DELAY REQUIRE_SPEAKER_ROUTE \
             GUARD_CTL GUARD_VALUE PLAYBACK_CTL PLAYBACK_VALUE \
             MIXER_CARD LOG_LEVEL LOG_MAX_KB; do
    grep -q "^[[:space:]]*$KEY=" "$DATADIR/stereo.conf" && continue
    DEF=$(grep "^$KEY=" "$MODPATH/config/stereo.conf" | head -n 1)
    [ -n "$DEF" ] || continue
    [ "$ADDED" -eq 0 ] && echo "" >> "$DATADIR/stereo.conf" && \
      echo "# --- added by v$(grep_prop version "$MODPATH/module.prop") ---" >> "$DATADIR/stereo.conf"
    echo "$DEF" >> "$DATADIR/stereo.conf"
    ADDED=$((ADDED + 1))
  done
  if [ "$ADDED" -gt 0 ]; then
    ui_print "  kept stereo.conf, added $ADDED new setting(s)"
  else
    ui_print "  keeping existing stereo.conf"
  fi
else
  cp -f "$MODPATH/config/stereo.conf" "$DATADIR/stereo.conf"
  ui_print "  installed default stereo.conf"
fi

# The guard is device-specific, so set it where we know what it should be.
if [ "$IS_CMF1" = 1 ]; then
  sed -i "s/^GUARD_CTL=.*/GUARD_CTL='aw_dev_0_switch'/; s/^GUARD_VALUE=.*/GUARD_VALUE='Enable'/" \
    "$DATADIR/stereo.conf" 2>/dev/null
  ui_print "  guard: earpiece follows the speaker amp"
  # Measured with 'stereoctl diff': this flips Off->On when media starts, and
  # media here is DSP-offloaded, so the procfs scan never sees it.
  sed -i "s/^PLAYBACK_CTL=.*/PLAYBACK_CTL='dsp_music_runtime_en'/; s/^PLAYBACK_VALUE=.*/PLAYBACK_VALUE='1'/" \
    "$DATADIR/stereo.conf" 2>/dev/null
  ui_print "  playback detected via dsp_music_runtime_en"
fi

# Ship the verified routing on the device it was verified on. An actions.conf
# that already has real content is never overwritten - that is the user's
# tuning, and it may well be better than the default.
EXISTING=0
[ -f "$DATADIR/actions.conf" ] && \
  EXISTING=$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' "$DATADIR/actions.conf" 2>/dev/null)
if [ "$EXISTING" -gt 0 ]; then
  ui_print "  keeping your actions.conf ($EXISTING actions)"
elif [ "$IS_CMF1" = 1 ]; then
  cp -f "$MODPATH/config/actions.cmf1.conf" "$DATADIR/actions.conf"
  ui_print "  installed the CMF Phone 1 routing profile"
else
  cp -f "$MODPATH/config/actions.conf" "$DATADIR/actions.conf"
  ui_print "  installed empty actions.conf (run 'stereoctl probe')"
fi
echo 0 > "$DATADIR/boot_pending"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/system/bin/stereoctl" 0 0 0755
chmod 0700 "$DATADIR" 2>/dev/null

##############################################################################
# report what the device can and cannot do
##############################################################################
ui_print " "
set_perm "$MODPATH/bin/tinymix" 0 0 0755

VENDOR_TINYMIX=""
for c in /vendor/bin/tinymix /system/bin/tinymix /odm/bin/tinymix /data/local/tmp/tinymix; do
  [ -x "$c" ] && { VENDOR_TINYMIX=$c; break; }
done
if [ -n "$VENDOR_TINYMIX" ]; then
  ui_print "  tinymix  : $VENDOR_TINYMIX (from the system)"
else
  ui_print "  tinymix  : bundled (this device ships none)"
  ui_print "             static aarch64 build of upstream tinyalsa;"
  ui_print "             provenance in bin/README.md"
fi

ACT=0
[ -f "$DATADIR/actions.conf" ] && ACT=$(grep -vcE '^[[:space:]]*#|^[[:space:]]*$' "$DATADIR/actions.conf" 2>/dev/null)
ui_print "  actions  : $ACT configured"

ui_print " "
if [ "$IS_CMF1" = 1 ] && [ "$EXISTING" -eq 0 ]; then
  ui_print "  Next steps"
  ui_print "  ----------"
  ui_print "  1. reboot"
  ui_print "  2. play something"
  ui_print "  3. stereoctl status   (should show the routing applied)"
  ui_print " "
  ui_print "  Earpiece gain starts at 8 of 18. Raise it in"
  ui_print "  /data/adb/cmf-stereo/actions.conf a step at a time and"
  ui_print "  stop at the first buzz - that damage is permanent."
else
  ui_print "  Next steps"
  ui_print "  ----------"
  ui_print "  1. reboot"
  ui_print "  2. in Termux:  su"
  ui_print "  3.             stereoctl probe"
  ui_print "  4. share the report from /sdcard/cmf-stereo-probe-*"
  ui_print " "
  ui_print "  Until actions.conf has routing in it, this module changes"
  ui_print "  nothing about how your phone sounds."
fi
ui_print " "
