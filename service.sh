#!/system/bin/sh
# late_start service: clear the boot watchdog, then hand off to the daemon.

MODDIR=${0%/*}
export MODDIR
. "$MODDIR/scripts/common.sh"

# Wait for a real boot before declaring this boot healthy.
_w=0
while [ "$(getprop sys.boot_completed)" != 1 ] && [ $_w -lt 180 ]; do
  sleep 2
  _w=$((_w + 2))
done
boot_strike_clear

if [ -f "$DATADIR/xml_overlay_auto_removed" ]; then
  log warn "the audio policy overlay was auto-removed after failed boots; re-apply with 'stereoctl xml-patch' only if you know why it failed"
  rm -f "$DATADIR/xml_overlay_auto_removed"
fi

chmod 0755 "$MODDIR/scripts/"*.sh "$MODDIR/scripts/stereoctl" 2>/dev/null

nohup "$MODDIR/scripts/stereo-daemon.sh" >/dev/null 2>&1 &
