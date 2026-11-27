# kHomestuck

Read Homestuck on a jailbroken Kindle in KOReader, page by page like the website: tap
"> next command", open Pesterlogs, GIF panels animate, and [S] animations play full screen
with sound over Bluetooth through KinAMP.

- **builder/**: turns the Unofficial Homestuck Collection asset pack into one pack per act or
  intermission (30 in all).
- **khomestuck.koplugin/**: the KOReader plugin. It downloads packs from the
  [kylep333/khomestuck-packs](https://github.com/kylep333/khomestuck-packs) release over HTTPS.
- **tools/build_all.sh**: builds sections in parallel and uploads each one to that release.
- **tools/push.sh**: copies built packs straight to a Kindle over SSH, without GitHub.
- **launcher/khomestuck.epub**: the Homestuck "book" for KOReader's library
  (`/mnt/us/documents/ebooks/`). Opening it, from the library or as the last-read book, opens
  Homestuck at your page, and its progress bar shows how far through Homestuck you are.
  Made by `launcher/make_book.py`, with `launcher/icon.png` as its cover.
- **launcher/homestuck.sh**: Kindle home screen tile (goes in `/mnt/us/documents/`) that opens
  that book. The same cover is embedded as base64 in its `# Icon:` line.

## Install on a Kindle (KPM)

Type in the Kindle search bar:
`;kpm add-repo https://kylep33.github.io/kile-kpm-repo/manifest.json`, then `;kpm update` and
`;kpm install khomestuck`. That installs the plugin, the Homestuck book and the home screen tile;
acts download from inside the app. For [S] sound also install KinAMP (kindletweaks repo).

Release a new plugin version to KPM: `./release.sh 1.0.1 "what changed"` (packs `kpm/` + the plugin
+ `launcher/` into a .kpkg in ../kile-kpm-repo and publishes it).

## Build and publish sections

```sh
tools/build_all.sh                 # every section not built yet, 4 at a time, each uploaded when done
FORCE=1 tools/build_all.sh 4 act1  # rebuild one section even though its pack exists
python3 -I builder/build.py list   # section ids
python3 -I builder/test_build.py   # builder checks
```

Uploads use the kylep333 account's gh token (`gh auth login` once for that account); the active
gh account isn't changed. The public `index.json` only lists packs that are already uploaded.

Needs, all inside this folder (and ignored by git):
- `data/assets.zip`: the 4.4 GB asset pack from https://storage.homestuck.com/uhc/assets.zip
- `ruffle/`: Ruffle, with its exporter built (`cargo build --release -p exporter`, Java on PATH)
- `tools/jre`, `tools/ffdec`, `tools/ffmpeg`: Java, JPEXS FFDec and a static ffmpeg

What each page's media becomes:
- still GIF/PNG → grayscale PNG, 1264 px wide
- animated GIF → dithered black/white frames with their real GIF timings, zlib per frame
- Flash → Ruffle renders it, kept at 8 fps, dithered, plus its best soundtrack (the HQ mp3, else
  the `_hqbaked.swf` remaster, else the original), re-encoded to 44.1 kHz stereo MP3.
  Interactive Flash (SWFNAV, or under 10 frames) becomes a note.

## Put sections on a Kindle without GitHub

```sh
tools/push.sh act1 act2    # SSH to root@kile-kindle (set KINDLE= for another)
```

## Reading

Open the **Homestuck** book in KOReader's library, the **Homestuck** tile on the Kindle home
screen, or KOReader's Tools tab → **Homestuck**. The book and the tile go straight to your page.
- **Continue reading** goes back to the last page you read. Each section remembers its own page.
- Tap a section to read it. Its cloud button downloads it; its trash button deletes it.
- **Options**: refresh the section list, download location, GIF autoplay, picture background.

On a page:
- Tap **> next command** or swipe left. Swipe right to go back.
- Tap an animated panel to pause it. Tap an [S] panel or **>> Play animation** to play it.
- Tap the footer for GIF autoplay and Go to page. The ✕ goes back to the sections window.
