#!/bin/sh
# Remove HP Legacy Printers (hp-legacy-printers-macos.pkg). Run with sudo.
# Printer queues that use these drivers are removed too, since they cannot print without them.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

for q in $(/usr/bin/lpstat -e 2>/dev/null); do
    if grep -q "/Library/Printers/HPLIP/filter/hpcups" "/private/etc/cups/ppd/$q.ppd" 2>/dev/null; then
        echo "removing printer $q"
        /usr/sbin/lpadmin -x "$q" || true
    fi
done
rm -rf /Library/Printers/HPLIP
rm -rf /Library/Printers/PPDs/Contents/Resources/HPLIP
rm -f "/Library/Printers/PPDs/Contents/Resources/HP DeskJet 2130 HPLIP.ppd.gz"   # left by the older DeskJet-2130-only package
rm -f /etc/paths.d/HPLIP
rm -rf "/Applications/HP Scan.app"
pkgutil --forget local.hplip.legacy-printers >/dev/null 2>&1 || true
pkgutil --forget local.hplip.deskjet2130 >/dev/null 2>&1 || true
/bin/launchctl kickstart -k system/org.cups.cupsd 2>/dev/null || true
echo "Removed."
