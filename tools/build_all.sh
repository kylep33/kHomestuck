#!/bin/sh
# Builds sections in parallel and uploads each one to the kylep333/khomestuck-packs release as
# soon as it finishes. Run from anywhere; logs go to logs/<section>.log.
# usage: tools/build_all.sh [jobs] [section...]    default: 4 jobs, every section not built yet
#        FORCE=1 tools/build_all.sh ...           rebuild sections even if their pack exists
set -e
cd "$(dirname "$0")/.."
JOBS=${1:-4}
[ $# -gt 0 ] && shift
SECTIONS=${*:-$(python3 -I builder/build.py list | awk '{print $1}')}
mkdir -p logs
# kylep333's token for uploads only, so the machine's active gh account stays as it is
GH_TOKEN=$(gh auth token --user kylep333)
export GH_TOKEN

for s in $SECTIONS; do [ -n "$FORCE" ] || [ ! -f "packs/$s.zip" ] && echo "$s"; done | xargs -P "$JOBS" -I{} sh -c '
    if python3 -I builder/build.py {} > logs/{}.log 2>&1; then
        # one upload at a time: zip first, then a section list that only offers uploaded zips
        if flock packs/.upload-lock sh -c "
            gh release upload packs packs/{}.zip --clobber -R kylep333/khomestuck-packs &&
            touch packs/{}.uploaded &&
            python3 -I builder/build.py index --uploaded &&
            gh release upload packs packs/index.json --clobber -R kylep333/khomestuck-packs
        " >> logs/{}.log 2>&1; then
            echo "$(date +%H:%M) uploaded {}"
        else
            echo "$(date +%H:%M) UPLOAD FAILED {} (logs/{}.log)"
        fi
    else
        echo "$(date +%H:%M) BUILD FAILED {} (logs/{}.log)"
    fi'
# leave index.json listing every local pack again, for tools/push.sh
python3 -I builder/build.py index
echo "all done"
