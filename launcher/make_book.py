"""Makes launcher/khomestuck.epub: a one-page "book" whose only job is to sit in KOReader's
library (and be its last-read book). The plugin recognizes it by file name and opens Homestuck
instead of showing it. Run: python3 -I launcher/make_book.py"""
import os, zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
OPF = """<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
 <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
  <dc:title>Homestuck</dc:title>
  <dc:creator opf:role="aut">Andrew Hussie</dc:creator>
  <dc:language>en</dc:language>
  <dc:identifier id="id">khomestuck</dc:identifier>
  <meta name="cover" content="cover-image"/>
 </metadata>
 <manifest>
  <item id="cover-image" href="cover.png" media-type="image/png"/>
  <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>
  <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
 </manifest>
 <spine toc="ncx"><itemref idref="cover"/></spine>
</package>"""
NCX = """<?xml version="1.0" encoding="utf-8"?>
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
 <head><meta name="dtb:uid" content="khomestuck"/></head>
 <docTitle><text>Homestuck</text></docTitle>
 <navMap><navPoint id="p1" playOrder="1"><navLabel><text>Homestuck</text></navLabel>
  <content src="cover.xhtml"/></navPoint></navMap>
</ncx>"""
COVER = """<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Homestuck</title></head>
<body style="margin:0;text-align:center"><img src="cover.png" alt="Homestuck" style="max-width:100%;max-height:100%"/></body></html>"""
CONTAINER = """<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
 <rootfiles><rootfile full-path="content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"""

with zipfile.ZipFile(os.path.join(HERE, "khomestuck.epub"), "w") as z:
    z.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)  # must be first, uncompressed
    z.writestr("META-INF/container.xml", CONTAINER, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("content.opf", OPF, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("toc.ncx", NCX, compress_type=zipfile.ZIP_DEFLATED)
    z.writestr("cover.xhtml", COVER, compress_type=zipfile.ZIP_DEFLATED)
    z.write(os.path.join(HERE, "icon.png"), "cover.png")
print("wrote", os.path.join(HERE, "khomestuck.epub"))
