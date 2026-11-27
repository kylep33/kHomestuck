#!/bin/sh
# Release kHomestuck to KPM: ./release.sh 1.2.3 "what changed"
# Sets the version, runs the builder tests, packs the .kpkg into the KPM repo (../kile-kpm-repo,
# or $KPM_REPO), lists it in the repo manifest, commits and pushes. The act packs are not part of
# this: they live in the kylep333/khomestuck-packs release and download from inside the app.
set -e
V=$1; MSG=$2
HERE=$(cd "$(dirname "$0")" && pwd); REPO=${KPM_REPO:-$HERE/../kile-kpm-repo}
echo "$V" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' && [ -n "$MSG" ] || { echo 'usage: release.sh X.Y.Z "what changed"'; exit 1; }
OUT=$REPO/packages/khomestuck/artifacts/khomestuck_${V}_kindleany.kpkg
[ ! -e "$OUT" ] || { echo "$OUT already exists"; exit 1; }
[ -z "$(git -C "$REPO" status --porcelain)" ] || { echo "$REPO has uncommitted changes"; exit 1; }

cd "$HERE"
sed -i -E "s/\"version\": \[[0-9, ]+\]/\"version\": [$(echo "$V" | sed 's/\./, /g')]/" kpm/manifest.json
python3 -I builder/test_build.py

# A .kpkg is a gzipped tar with the package files at its root.
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp kpm/manifest.json kpm/install.sh kpm/uninstall.sh launcher/homestuck.sh launcher/khomestuck.epub "$STAGE/"
cp -r khomestuck.koplugin "$STAGE/"
mkdir -p "$(dirname "$OUT")"
cp launcher/icon.png "$REPO/packages/khomestuck/cover.png"
(cd "$STAGE" && tar czf "$OUT" *)

python3 - "$REPO/manifest.json" "$V" "$HERE/kpm/manifest.json" <<'EOF'
import json, sys
path, v, pkg = sys.argv[1], sys.argv[2], json.load(open(sys.argv[3]))
m = json.load(open(path))
entry = m["packages"].setdefault("khomestuck", {"artifacts": []})
entry.update(name=pkg["name"], author=pkg["author"], description=pkg["description"])
entry["artifacts"].append({"url": f"packages/khomestuck/artifacts/khomestuck_{v}_kindleany.kpkg",
    "version": [int(x) for x in v.split(".")], "dependencies": [], "supported_platforms": None})
open(path, "w").write(json.dumps(m))
EOF

git add kpm/manifest.json && git commit -q -m "kHomestuck $V: $MSG" || true
cd "$REPO"
git add manifest.json "$OUT" packages/khomestuck/cover.png
git commit -q -m "khomestuck $V: $MSG"
git push -q
gh workflow run publish.yml -R "$(git remote get-url origin | sed -E 's#.*github.com[:/]##; s#\.git$##')"  # pushes have not been triggering the deploy
echo "released khomestuck $V"
