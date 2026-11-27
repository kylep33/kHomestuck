#!/bin/sh
# On upgrade KPM reinstalls right after, so keep everything.
[ "$1" = "upgrade" ] && exit 0
rm -rf /mnt/us/koreader/plugins/khomestuck.koplugin
rm -f /mnt/us/koreader/icons/homestuck.svg /mnt/us/documents/homestuck.sh
for d in /mnt/us/documents /mnt/us/documents/ebooks; do  # the two places install.sh uses
    rm -rf "$d/khomestuck.epub" "$d/khomestuck.sdr"
done
# downloaded acts can be gigabytes; they download again on a reinstall
rm -rf /mnt/us/homestuck
echo "kHomestuck removed."
