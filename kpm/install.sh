#!/bin/sh
# KPM runs this from the package folder after unpacking. KOReader loads the plugin on its next start.
PLUGINS=/mnt/us/koreader/plugins
DOCS=/mnt/us/documents
[ -d "$PLUGINS" ] || { echo "KOReader not found at /mnt/us/koreader"; exit 1; }

rm -rf "$PLUGINS/khomestuck.koplugin"
cp -r khomestuck.koplugin "$PLUGINS/"

# The Homestuck book: documents/ebooks if it's already there, otherwise documents. Only these two
# exact paths: a search also finds copies inside backup folders.
BOOK=$DOCS/khomestuck.epub
[ -f "$DOCS/ebooks/khomestuck.epub" ] && BOOK=$DOCS/ebooks/khomestuck.epub
cp khomestuck.epub "$BOOK"

# Home screen tile, pointed at that book.
sed "s|/mnt/us/documents/ebooks/khomestuck.epub|$BOOK|" homestuck.sh > "$DOCS/homestuck.sh"
chmod +x "$DOCS/homestuck.sh"

[ -x /mnt/us/KinAMP/startkinamp_koreader.sh ] || echo "For [S] sound, also install KinAMP (kindletweaks repo)."
echo "kHomestuck installed. Restart KOReader, then open the Homestuck book."
