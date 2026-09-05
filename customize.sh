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

case "$(getprop ro.product.device)$(getprop ro.product.model)" in
  *[Tt]etris*|*CMF*|*cmf*) : ;;
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

for f in stereo.conf actions.conf; do
  if [ -f "$DATADIR/$f" ]; then
    ui_print "  keeping existing $f"
  else
    cp -f "$MODPATH/config/$f" "$DATADIR/$f"
    ui_print "  installed default $f"
  fi
done
echo 0 > "$DATADIR/boot_pending"

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm_recursive "$MODPATH/scripts" 0 0 0755 0755
set_perm "$MODPATH/system/bin/stereoctl" 0 0 0755
chmod 0700 "$DATADIR" 2>/dev/null

##############################################################################
# report what the device can and cannot do
##############################################################################
ui_print " "
TINYMIX=""
for c in /vendor/bin/tinymix /system/bin/tinymix /odm/bin/tinymix /data/local/tmp/tinymix; do
  [ -x "$c" ] && { TINYMIX=$c; break; }
done
if [ -n "$TINYMIX" ]; then
  ui_print "  tinymix  : $TINYMIX"
else
  ui_print "  tinymix  : NOT FOUND"
  ui_print "             mixer control needs it. The probe still runs and"
  ui_print "             will collect everything else. See the README."
fi

ACT=0
[ -f "$DATADIR/actions.conf" ] && ACT=$(grep -vc '^[[:space:]]*#\|^[[:space:]]*$' "$DATADIR/actions.conf" 2>/dev/null)
ui_print "  actions  : $ACT configured"

ui_print " "
ui_print "  Next steps"
ui_print "  ----------"
ui_print "  1. reboot"
ui_print "  2. in Termux:  su"
ui_print "  3.             stereoctl probe"
ui_print "  4. share the report from /sdcard/cmf-stereo-probe-*"
ui_print " "
ui_print "  Until actions.conf has routing in it, this module changes"
ui_print "  nothing about how your phone sounds."
ui_print " "
