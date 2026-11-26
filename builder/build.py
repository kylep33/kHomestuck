"""Build one Homestuck section (an act or intermission) into a pack the Kindle plugin downloads.

usage: python3 builder/build.py <section_id>... | all | list | index [--uploaded]

Reads data/assets.zip (the Unofficial Homestuck Collection asset pack) and writes packs/<id>.zip.
"index" writes the section list: packs/index.local.json (every built pack), or with --uploaded
packs/index.json (only packs already on GitHub). tools/build_all.sh does builds and uploads.

A pack holds section.json and media files:
  img/<name>.png    still panel, grayscale
  anim/<name>.bin   looping GIF panel: zlib-compressed 1-bit-looking (0/255) frames back to back
  clip/<page>.bin   [S] animation frames (same format) + clip/<page>.mp3
Frame offsets and timings are in section.json, so the Kindle can seek to any frame.
"""
import io, json, os, re, shutil, struct, subprocess, sys, tempfile, zipfile, zlib
from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "data", "assets.zip")
PACKS = os.path.join(ROOT, "packs")
WORK = os.path.join(ROOT, "work")
EXPORTER = os.path.join(ROOT, "ruffle", "target", "release", "exporter")
FFDEC = os.path.join(ROOT, "tools", "ffdec", "ffdec-cli.jar")
JAVA = os.path.join(ROOT, "tools", "jre", "bin", "java")
FFMPEG = os.path.join(ROOT, "tools", "ffmpeg", "ffmpeg")
WIDTH = 1264  # Paperwhite 6 portrait width (1272) minus a small margin
CLIP_FPS = 8  # measured fine on the Paperwhite 6 with full-width A2 refreshes
CHUNK = 400   # exporter keeps every frame in RAM, so render long flashes in slices

# (id, name, first page). Each section ends where the next starts. From UHC's getChapter.
SECTIONS = [
    ("act1", "Act 1", 1901), ("act2", "Act 2", 2149), ("act3", "Act 3", 2660),
    ("int1", "Intermission", 3054), ("act4", "Act 4", 3258),
    ("act5-1", "Act 5 Act 1", 3889), ("act5-2", "Act 5 Act 2", 4526),
    ("int2", "Intermission 2", 6011), ("act6-1", "Act 6 Act 1", 6013),
    ("act6-i1", "Act 6 Intermission 1", 6195), ("act6-2", "Act 6 Act 2", 6320),
    ("act6-i2", "Act 6 Intermission 2", 6567), ("act6-3", "Act 6 Act 3", 6720),
    ("act6-i3", "Act 6 Intermission 3", 7163), ("act6-4", "Act 6 Act 4", 7338),
    ("act6-i4", "Act 6 Intermission 4", 7341), ("act6-5", "Act 6 Act 5", 7412),
    ("act6-i5", "Act 6 Intermission 5", 7823), ("act6-6-1", "Act 6 Act 6 Act 1", 8143),
    ("act6-6-i1", "Act 6 Act 6 Intermission 1", 8178), ("act6-6-2", "Act 6 Act 6 Act 2", 8375),
    ("act6-6-i2", "Act 6 Act 6 Intermission 2", 8431), ("act6-6-3", "Act 6 Act 6 Act 3", 8753),
    ("act6-6-i3", "Act 6 Act 6 Intermission 3", 8801), ("act6-6-4", "Act 6 Act 6 Act 4", 8821),
    ("act6-6-i4", "Act 6 Act 6 Intermission 4", 8844), ("act6-6-5", "Act 6 Act 6 Act 5", 9309),
    ("act6-6-i5", "Act 6 Act 6 Intermission 5", 9349), ("act6-6-6", "Act 6 Act 6 Act 6", 9987),
    ("act7", "Act 7", 10027),
]
LAST_PAGE = 10030

# Ordered (Bayer) dither: a gray always gives the same dots, so still areas don't shimmer.
B8 = [[0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
      [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
      [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
      [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]]
_tmaps = {}


def dither(gray):
    tmap = _tmaps.get(gray.size)
    if tmap is None:
        tile = Image.new("L", (8, 8))
        tile.putdata([v * 4 + 2 for row in B8 for v in row])
        tmap = Image.new("L", gray.size)
        for y in range(0, gray.size[1], 8):
            for x in range(0, gray.size[0], 8):
                tmap.paste(tile, (x, y))
        _tmaps[gray.size] = tmap
    # white where gray > threshold: subtract clips at 0, so any positive difference is white
    return ImageChops.subtract(gray, tmap).point(lambda v: 255 if v else 0)


def fit(im):
    im = im.convert("RGB").convert("L")
    return im.resize((WIDTH, round(im.height * WIDTH / im.width)), Image.LANCZOS)


class FrameWriter:
    """Writes zlib-compressed frames back to back and records where each starts."""
    def __init__(self, path):
        self.f, self.offsets, self.size = open(path, "wb"), [], None

    def add(self, gray):
        if self.size is None:
            self.size = gray.size
        assert gray.size == self.size, "frame size changed mid-clip"
        self.offsets.append(self.f.tell())
        self.f.write(zlib.compress(dither(gray).tobytes(), 6))

    def close(self):
        self.offsets.append(self.f.tell())  # end of the last frame
        self.f.close()
        return {"w": self.size[0], "h": self.size[1], "offsets": self.offsets}


def swf_header(data):
    if data[:3] == b"CWS":
        body = zlib.decompress(data[8:])
    elif data[:3] == b"FWS":
        body = data[8:]
    else:
        raise ValueError("unsupported SWF compression " + data[:3].decode("latin1"))
    rect = (5 + 4 * (body[0] >> 3) + 7) // 8
    fps = body[rect + 1] + body[rect] / 256
    frames = struct.unpack("<H", body[rect + 2:rect + 4])[0]
    return fps, frames


def build_clip(z, swf_name, page_id, out, tmp):
    """[S] page: render the SWF with Ruffle, keep CLIP_FPS frames, attach its audio."""
    data = z.read(swf_name)
    fps, frames = swf_header(data)
    swf = os.path.join(tmp, "in.swf")
    open(swf, "wb").write(data)
    w = FrameWriter(os.path.join(out, "clip", page_id + ".bin"))
    want = [int(i * fps / CLIP_FPS) for i in range(int(frames / fps * CLIP_FPS))]
    for start in range(0, frames, CHUNK):
        pngs = os.path.join(tmp, "png")
        shutil.rmtree(pngs, ignore_errors=True)
        n = min(CHUNK, frames - start)
        subprocess.run([EXPORTER, "-s", "--force-play", "--skipframes", str(start), "--frames", str(n),
                        "--scale", str(WIDTH / 650), swf, pngs], check=True, capture_output=True)
        files = sorted(os.listdir(pngs)) if os.path.isdir(pngs) else [os.path.basename(pngs)]
        for k in want:
            if start <= k < start + n and k - start < len(files):
                w.add(fit(Image.open(os.path.join(pngs, files[k - start]))))
    meta = w.close()
    meta.update(kind="clip", fps=CLIP_FPS, bin="clip/%s.bin" % page_id,
                poster=min(len(meta["offsets"]) - 2, 2 * CLIP_FPS))
    audio = clip_audio(z, swf_name, swf, tmp)
    if audio:
        shutil.copyfile(audio, os.path.join(out, "clip", page_id + os.path.splitext(audio)[1]))
        meta["audio"] = "clip/" + page_id + os.path.splitext(audio)[1]
    return meta


def clip_audio(z, swf_name, swf, tmp):
    """The best soundtrack for a flash, as 44.1 kHz stereo MP3.

    Prefers the remastered audio: a separate HQ mp3 next to the SWF, then the sound baked into
    _hqbaked.swf, and only then the original SWF's (often ~11 kHz, which the Kindle's audio
    output resamples into an audible buzz). Everything is re-encoded to 44.1 kHz for that reason."""
    stem = os.path.splitext(swf_name.replace("_hq.swf", ".swf"))[0]
    src = None
    if stem + ".mp3" in z.NameToInfo:
        src = os.path.join(tmp, "audio_src.mp3")
        open(src, "wb").write(z.read(stem + ".mp3"))
    else:
        for cand in (stem + "_hqbaked.swf", stem + "_hq.swf", stem + ".swf"):
            if cand not in z.NameToInfo:
                continue
            path = os.path.join(tmp, "snd_src.swf")
            open(path, "wb").write(z.read(cand))
            snd = os.path.join(tmp, "snd")
            shutil.rmtree(snd, ignore_errors=True)
            subprocess.run([JAVA, "-jar", FFDEC, "-export", "sound", snd, path], check=True, capture_output=True)
            files = [os.path.join(dp, f) for dp, _, fs in os.walk(snd) for f in fs]
            if files:
                # shortcut: assumes the largest sound is the soundtrack and starts on frame 1, check per flash once whole acts are built
                src = max(files, key=os.path.getsize)
                break
    if not src:
        return None
    out = os.path.join(tmp, "audio.mp3")
    subprocess.run([FFMPEG, "-y", "-v", "error", "-i", src, "-ar", "44100", "-ac", "2", "-b:a", "128k", out],
                   check=True, capture_output=True)
    return out


def build_media(z, path, page, out, tmp):
    name = "Asset_Pack" + path
    ext = os.path.splitext(path)[1].lower()
    base = re.sub(r"[^\w.-]", "_", os.path.basename(path).rsplit(".", 1)[0])
    if ext in (".gif", ".png", ".jpg"):
        im = Image.open(io.BytesIO(z.read(name)))
        if getattr(im, "n_frames", 1) > 1:
            w = FrameWriter(os.path.join(out, "anim", base + ".bin"))
            durations = []
            for i in range(im.n_frames):
                im.seek(i)
                w.add(fit(im))
                durations.append(im.info.get("duration") or 100)
            meta = w.close()
            meta.update(kind="anim", bin="anim/%s.bin" % base, durations=durations)
            return meta
        im = fit(im)
        im.save(os.path.join(out, "img", base + ".png"), optimize=True)
        return {"kind": "img", "src": "img/%s.png" % base, "w": im.width, "h": im.height}
    if ext == ".swf":
        fps, frames = swf_header(z.read(name))
        if "SWFNAV" in page["flag"] or frames < 10:
            return {"kind": "none", "note": "Interactive Flash: play it on a computer."}
        try:
            return build_clip(z, name, page["pageId"], out, tmp)
        except Exception as e:  # one broken flash shouldn't cost the whole section
            print("  clip failed:", page["pageId"], repr(e)[:300], flush=True)
            for ext_ in (".bin", ".mp3", ".wav"):
                p = os.path.join(out, "clip", page["pageId"] + ext_)
                if os.path.exists(p):
                    os.remove(p)
            return {"kind": "none", "note": "This animation couldn't be converted."}
    return {"kind": "none", "note": "Not supported on Kindle (%s)." % ext}


MSPA_LINK = re.compile(r'href="[^"]*mspaintadventures\.com/\?s=6&(?:amp;)?p=(\d{6})"')


def page_text(content):
    log = None
    m = re.match(r"^\|(.*?)\|\s*(<br ?/?>)?", content)
    if m:
        log, content = m.group(1), content[m.end():]
    content = MSPA_LINK.sub(r'href="page:\1"', content)
    return log, content


def build(sid, story, z):
    i = [s[0] for s in SECTIONS].index(sid)
    first = SECTIONS[i][2]
    last = SECTIONS[i + 1][2] - 1 if i + 1 < len(SECTIONS) else LAST_PAGE
    # on disk, not /tmp: /tmp is RAM-backed here, and four big sections at once filled it
    os.makedirs(WORK, exist_ok=True)
    tmp = tempfile.mkdtemp(prefix="khs-", dir=WORK)
    try:
        build_into(sid, i, first, last, story, z, tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def build_into(sid, i, first, last, story, z, tmp):
    out = os.path.join(tmp, sid)
    for d in ("img", "anim", "clip"):
        os.makedirs(os.path.join(out, d))
    pages, order = {}, []
    for n in range(first, last + 1):
        pid = "%06d" % n
        if pid not in story:
            continue
        p = story[pid]
        log, text = page_text(p["content"])
        nxt = p["next"][-1:] if p["next"] else []  # branches list the hidden password page first
        page = {
            "title": p["title"], "log": log, "text": text,
            "media": [build_media(z, m, p, out, tmp) for m in p["media"]],
            "next": [{"id": x, "title": story[x]["title"]} for x in nxt if x in story],
            "prev": p.get("previous"),
        }
        # no nulls: KOReader's rapidjson decodes null as a truthy userdata
        pages[pid] = {k: v for k, v in page.items() if v is not None}
        order.append(pid)
        print(sid, pid, [m["kind"] for m in pages[pid]["media"]], flush=True)
    json.dump({"id": sid, "name": SECTIONS[i][1], "first": order[0], "last": order[-1],
               "order": order, "pages": pages}, open(os.path.join(out, "section.json"), "w"))
    os.makedirs(PACKS, exist_ok=True)
    zpath = os.path.join(PACKS, sid + ".zip")
    with zipfile.ZipFile(zpath + ".part", "w", zipfile.ZIP_STORED) as zf:  # media is already compressed
        for dp, _, fs in os.walk(out):
            for f in fs:
                zf.write(os.path.join(dp, f), os.path.relpath(os.path.join(dp, f), tmp))
    os.replace(zpath + ".part", zpath)
    check(zpath, sid)
    # no write_index() here: parallel builds rewriting the list raced with uploads (see "index")


def check(zpath, sid):
    """Self-check a finished pack: every frame inflates to w*h pure black/white bytes."""
    with zipfile.ZipFile(zpath) as zf:
        sec = json.loads(zf.read(sid + "/section.json"))
        assert sec["order"] and all(p in sec["pages"] for p in sec["order"])
        for p in sec["pages"].values():
            for m in p["media"]:
                if m["kind"] in ("anim", "clip"):
                    data, o = zf.read(sid + "/" + m["bin"]), m["offsets"]
                    assert len(o) >= 2 and o[-1] == len(data), m["bin"]
                    f0 = zlib.decompress(data[o[0]:o[1]])
                    assert len(f0) == m["w"] * m["h"] and set(f0) <= {0, 255}, m["bin"]
                elif m["kind"] == "img":
                    zf.getinfo(sid + "/" + m["src"])


def write_index(uploaded_only=False):
    """Lists every section; built ones also carry their size, so the Kindle can offer them.

    uploaded_only writes packs/index.json, the public list: it only offers sections marked
    packs/<id>.uploaded, so a Kindle never sees a pack that isn't on GitHub yet.
    Otherwise writes packs/index.local.json, offering every built pack (for tools/push.sh)."""
    index = []
    for i, (sid, name, first) in enumerate(SECTIONS):
        last = SECTIONS[i + 1][2] - 1 if i + 1 < len(SECTIONS) else LAST_PAGE
        entry = {"id": sid, "name": name, "first": "%06d" % first, "last": "%06d" % last}
        zpath = os.path.join(PACKS, sid + ".zip")
        offered = os.path.exists(os.path.join(PACKS, sid + ".uploaded")) if uploaded_only else True
        if offered and os.path.exists(zpath):
            with zipfile.ZipFile(zpath) as zf:
                sec = json.loads(zf.read(sid + "/section.json"))
            entry.update(first=sec["first"], last=sec["last"], pages=len(sec["order"]),
                         size=os.path.getsize(zpath))
        index.append(entry)
    os.makedirs(PACKS, exist_ok=True)
    path = os.path.join(PACKS, "index.json" if uploaded_only else "index.local.json")
    tmp = "%s.%d.tmp" % (path, os.getpid())  # own temp name per process, then an atomic rename
    with open(tmp, "w") as f:
        json.dump({"sections": index}, f, indent=1)
    os.replace(tmp, path)


def main(args):
    if not args or args == ["list"]:
        for s in SECTIONS:
            print(*s)
        return
    if args[0] == "index":
        return write_index(uploaded_only="--uploaded" in args)
    z = zipfile.ZipFile(ASSETS)
    story = json.loads(z.read("Asset_Pack/archive/data/mspa.json"))["story"]
    for sid in ([s[0] for s in SECTIONS] if args == ["all"] else args):
        build(sid, story, z)


if __name__ == "__main__":
    main(sys.argv[1:])
