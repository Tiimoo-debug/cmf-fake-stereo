#!/system/bin/sh
# Runs before module files are mounted. This is the boot watchdog: if the
# previous two boots never reached sys.boot_completed while our audio policy
# overlay was active, the overlay is removed before it can be mounted again.
#
# That turns a bad policy into "reboot once more and it is gone" instead of a
# trip to recovery - which is exactly how the Hi-Res Audio module bricks boots.

MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"

OVERLAY_XML=$(find "$MODDIR/system" -name 'audio_policy_configuration*.xml' 2>/dev/null)

if [ -n "$OVERLAY_XML" ] && [ "$(boot_strikes)" -ge 2 ]; then
  log warn "boot watchdog: $(boot_strikes) failed boots with the policy overlay active - removing it"
  for f in $OVERLAY_XML; do rm -f "$f"; log warn "  removed $f"; done
  find "$MODDIR/system" -type d -empty -delete 2>/dev/null
  mkdir -p "$MODDIR/system/bin"
  touch "$DATADIR/xml_overlay_auto_removed"
  boot_strike_clear
fi

# Anything active this boot counts as a strike until service.sh clears it.
if [ -n "$OVERLAY_XML" ] || [ "$(action_count)" -gt 0 ]; then
  boot_strike_add
fi

exit 0
