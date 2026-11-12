#!/usr/bin/env python3
"""Rewrite HPLIP's hpcups PPDs for macOS.

usage: make-ppds.py SRC_PPD_DIR OUT_DIR FILTER_PATH SUPPORTED_LIST

For each PPD whose printer language our macOS hpcups build supports and that
does not need HP's proprietary plugin:
  * point *cupsFilter at FILTER_PATH (macOS keeps third-party filters out of the
    SIP-protected /usr/libexec/cups/filter, so PPDs reference them absolutely)
  * tag the NickName with "(macOS)" so it is recognisable in Add Printer
  * pcl3gui2 only: request RGB instead of RGBW in color mode. hpcups moves pure
    black into a separate K plane for RGBW, but since HPLIP 3.21 the PCL3GUI2
    encoder is color-only and drops that plane, so pure black never printed.
Writes the list of supported models (one NickName per line) to SUPPORTED_LIST.
"""
import gzip
import os
import re
import sys

# Encapsulators compiled into our hpcups. Left out: hbpl1, ljjetready and
# quickconnect (need libjpeg) and ljzjstream/ljzxstream (need HP's closed JBIG plugin).
SUPPORTED_LANGUAGES = {"pcl3gui2", "pcl3gui", "pcl3", "lidil", "ljmono", "ljcolor", "ljfastraster"}

src, out, filter_path, supported_list = sys.argv[1:5]
os.makedirs(out, exist_ok=True)
for old in os.listdir(out):
    if old.endswith(".ppd.gz"):
        os.remove(os.path.join(out, old))

kept, skipped = [], {}
for name in sorted(os.listdir(src)):
    if not name.endswith(".ppd.gz"):
        continue
    text = gzip.open(os.path.join(src, name), "rb").read().decode("latin-1")
    lang = re.search(r'^\*hpPrinterLanguage: "([^"]+)"', text, re.M).group(1)
    nick = re.search(r'^\*NickName: "([^"]+)"', text, re.M).group(1)
    if lang not in SUPPORTED_LANGUAGES or "proprietary plugin" in nick:
        reason = lang if lang not in SUPPORTED_LANGUAGES else "plugin"
        skipped[reason] = skipped.get(reason, 0) + 1
        continue

    text, n = re.subn(r'^\*cupsFilter: "application/vnd\.cups-raster 0 hpcups"',
                      f'*cupsFilter: "application/vnd.cups-raster 0 {filter_path}"', text, flags=re.M)
    assert n == 1, f"{name}: expected one cupsFilter line"
    text = re.sub(r'^(\*NickName: ")([^"]+)"', r'\1\2 (macOS)"', text, count=1, flags=re.M)
    if lang == "pcl3gui2":
        text = re.sub(r'^(\*ColorModel RGB/Color: "<</cupsColorSpace )17/', r"\g<1>1/", text, flags=re.M)
    # Upstream bug in ~20 newer PPDs (ENVY 6100/6500, Smart Tank, ...): the
    # default page size is "Letter" but the size itself is named "US_LETTER".
    if not re.search(r"^\*PageSize Letter[/:]", text, re.M) and re.search(r"^\*PageSize US_LETTER[/:]", text, re.M):
        text = re.sub(r"^(\*Default(?:PageSize|PageRegion|ImageableArea|PaperDimension): )Letter\s*$",
                      r"\g<1>US_LETTER", text, flags=re.M)
    # A few Smart Tank PPDs define the same page-size choice twice; keep the first.
    seen, lines = set(), []
    for line in text.split("\n"):
        m = re.match(r"\*(PageSize|PageRegion|ImageableArea|PaperDimension) ([^/:\s]+)[/:]", line)
        if m and m.groups() in seen:
            continue
        if m:
            seen.add(m.groups())
        lines.append(line)
    text = "\n".join(lines)
    # PPD spec caps ShortNickName at 31 characters; a few HP names exceed it.
    text = re.sub(r'^(\*ShortNickName: ")([^"]{32,})"', lambda m: f'{m.group(1)}{m.group(2)[:31].rstrip()}"',
                  text, flags=re.M)
    # The same PPDs carry UIConstraints naming choices they never define
    # (e.g. "*PageSize 2L.FB"); drop those constraints so the PPD validates.
    choices = set(re.findall(r"^\*(\w+) ([^/:\s]+)[/:]", text, re.M))
    def constraint_ok(m):
        refs = re.findall(r"\*(\w+)(?:\s+([^\s*]+))?", m.group(1))
        return all(not c or (k, c) in choices for k, c in refs)
    text = re.sub(r"^\*(?:UI|NonUI)Constraints: (.*)\n",
                  lambda m: m.group(0) if constraint_ok(m) else "", text, flags=re.M)

    with gzip.GzipFile(os.path.join(out, name), "wb", compresslevel=9, mtime=0) as f:
        f.write(text.encode("latin-1"))
    kept.append(nick)

with open(supported_list, "w") as f:
    f.write("\n".join(sorted(kept, key=str.lower)) + "\n")
print(f"make-ppds: wrote {len(kept)} PPDs; skipped {sum(skipped.values())} {skipped}")
