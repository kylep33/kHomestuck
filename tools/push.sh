#!/bin/sh
# Copy built sections from packs/ to the Kindle over SSH. Run from the repo root.
# usage: tools/push.sh <section>...      e.g. tools/push.sh act1 act2
set -e
KINDLE=${KINDLE:-root@kile-kindle}
ROOT=/mnt/us/homestuck
[ $# -gt 0 ] || { echo "usage: $0 <section>..." >&2; exit 1; }
for sid in "$@"; do
    case "$sid" in *[!a-z0-9-]*) echo "bad section id: $sid" >&2; exit 1 ;; esac
    [ -f "packs/$sid.zip" ] || { echo "packs/$sid.zip not built" >&2; exit 1; }
    echo "pushing $sid"
    ssh "$KINDLE" "mkdir -p $ROOT && rm -rf $ROOT/$sid $ROOT/$sid.zip"
    ssh "$KINDLE" "cat > $ROOT/$sid.zip && unzip -q -o $ROOT/$sid.zip -d $ROOT && rm $ROOT/$sid.zip && touch $ROOT/$sid/.complete" < "packs/$sid.zip"
done
# the plugin lists sections from this file when it can't reach GitHub
python3 -I builder/build.py index
ssh "$KINDLE" "cat > $ROOT/index.json" < packs/index.local.json
echo done
