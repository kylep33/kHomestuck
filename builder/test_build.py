"""Checks for the builder's text parsing and section lists. Run: python3 -I builder/test_build.py"""
import json, os, sys, tempfile, zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build  # noqa: E402

# Pesterlog marker comes off the text and becomes the log name
log, text = build.page_text('|PESTERLOG|<br />-- turntechGodhead began pestering ectoBiologist --')
assert log == "PESTERLOG", log
assert text == "-- turntechGodhead began pestering ectoBiologist --", text

# plain pages keep their text and have no log
assert build.page_text("A young man stands in his bedroom.") == (None, "A young man stands in his bedroom.")

# old site links point at pages the plugin can open
_, text = build.page_text('<a href="http://www.mspaintadventures.com/?s=6&amp;p=001926">here</a>')
assert text == '<a href="page:001926">here</a>', text

# the public list only offers uploaded packs; the local list offers every built pack
with tempfile.TemporaryDirectory() as d:
    build.PACKS = d
    for sid in ("act1", "act2"):
        with zipfile.ZipFile(os.path.join(d, sid + ".zip"), "w") as zf:
            zf.writestr(sid + "/section.json", json.dumps({"first": "001901", "last": "001902", "order": ["001901"]}))
    open(os.path.join(d, "act1.uploaded"), "w").close()

    build.write_index(uploaded_only=True)
    public = {s["id"]: s for s in json.load(open(os.path.join(d, "index.json")))["sections"]}
    assert "size" in public["act1"] and "size" not in public["act2"], public
    assert len(public) == len(build.SECTIONS)

    build.write_index()
    local = {s["id"]: s for s in json.load(open(os.path.join(d, "index.local.json")))["sections"]}
    assert "size" in local["act1"] and "size" in local["act2"], local
    assert not [f for f in os.listdir(d) if f.endswith(".tmp")], "temp list file left behind"

print("ok")
