#!/bin/sh
# Read-only diagnostics for HP Legacy Printers (HPLIP for macOS).
# Usage:  sh diagnose.sh > ~/Desktop/hp-diagnose.txt 2>&1
# Changes nothing. Asks for no password; the log section is just shorter without sudo.

section() { printf '\n===== %s =====\n' "$1"; }

section "system"
sw_vers; uname -m; date

section "package receipt"
pkgutil --pkgs | grep -i hplip
pkgutil --pkg-info local.hplip.legacy-printers 2>&1
pkgutil --pkg-info local.hplip.deskjet2130 2>&1

section "installed files"
ls -la /Library/Printers/ /Library/Printers/PPDs/Contents/Resources/ 2>&1
echo "HPLIP PPDs installed: $(ls /Library/Printers/PPDs/Contents/Resources/HPLIP 2>/dev/null | wc -l)"
ls -laR /Library/Printers/HPLIP 2>&1 | head -40
ls -la "/Applications/HP Scan.app/Contents/MacOS" 2>&1

section "binary architectures and signatures"
for f in /Library/Printers/HPLIP/filter/hpcups /Library/Printers/HPLIP/bin/hpscan \
         /Library/Printers/HPLIP/lib/libsane-hpaio.so; do
    lipo -info "$f" 2>&1
    codesign -dv "$f" 2>&1 | grep -E "Signature|flags|Executable"
done

section "USB: is the printer seen?"
system_profiler SPUSBDataType SPUSBHostDataType 2>/dev/null | grep -B2 -A8 "0x03f0" | head -40

section "CUPS USB devices (lpinfo -l -v)"
lpinfo -l --include-schemes usb -v 2>&1

section "CUPS drivers"
echo "HPLIP drivers listed: $(lpinfo -m 2>/dev/null | grep -c 'Resources/HPLIP/')  (all drivers: $(lpinfo -m 2>/dev/null | wc -l))"
lpinfo -l --include-schemes usb -v 2>/dev/null | sed -n 's/^ *device-id = //p' | while read -r id; do
    echo "best matches for $id:"; lpinfo -m --device-id "$id" 2>&1 | head -3
done

section "queue PPDs"
for q in $(lpstat -e 2>/dev/null); do
    echo "$q:"; grep -E "^\*(NickName|cupsFilter|PCFileName)" "/private/etc/cups/ppd/$q.ppd" 2>&1
done

section "queues"
lpstat -t 2>&1 | head -20

section "installer log (postinstall)"
grep -E "hplip|postinstall|preinstall|lpadmin" /var/log/install.log 2>/dev/null | tail -40

section "CUPS error log"
tail -40 /private/var/log/cups/error_log 2>&1

section "scanner"
/Library/Printers/HPLIP/bin/hpscan -L 2>&1
