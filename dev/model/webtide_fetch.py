#!/usr/bin/env python3
"""Acquire the DFO WebTide "Northeast Pacific" (ne_pac4) model data.

DFO distributes the model inside an install4j self-extracting installer whose
payload is a set of individually-deflated zip local records (no central
directory, so `unzip` can't read it). We download the Unix installer and pull
the `data/ne_pac4/*` members out directly by walking the PK\\x03\\x04 headers.

This is the source of the offline current constituents north of the
SalishSeaCast domain (see dev/model/webtide_extract.py). LICENSE NOTE: WebTide's
commercial-redistribution terms are unconfirmed pending DFO/BIO sign-off — this
script is for development/evaluation; do not ship the derived data until the
license question is resolved.

Idempotent: skips the download if the installer is already present.
"""
import os, struct, zlib, urllib.request, sys

URL = ("https://www.bio.gc.ca/science/research-recherche/ocean/webtide/"
       "Application/Install/InstData/Data/Unix/WebTide_ne_pac_data_0_7.sh")
HERE = os.path.dirname(os.path.abspath(__file__))
DEST = os.path.join(HERE, "webtide")
INSTALLER = os.path.join(DEST, "WebTide_ne_pac_data_0_7.sh")
OUTDIR = os.path.join(DEST, "ne_pac4")


def download():
    os.makedirs(DEST, exist_ok=True)
    if os.path.exists(INSTALLER) and os.path.getsize(INSTALLER) > 1_000_000:
        print(f"installer present ({os.path.getsize(INSTALLER)} bytes), skipping download")
        return
    print(f"downloading {URL}")
    urllib.request.urlretrieve(URL, INSTALLER)
    print(f"  -> {INSTALLER} ({os.path.getsize(INSTALLER)} bytes)")


def extract():
    data = open(INSTALLER, "rb").read()
    os.makedirs(OUTDIR, exist_ok=True)
    sig = b"PK\x03\x04"
    off = 0
    got = 0
    while True:
        j = data.find(sig, off)
        if j < 0:
            break
        off = j + 4
        try:
            (_, ver, flags, method, tm, dt, crc,
             csize, usize, nlen, elen) = struct.unpack("<IHHHHHIIIHH", data[j:j + 30])
        except struct.error:
            continue
        if not (0 < nlen < 300):
            continue
        name = data[j + 30:j + 30 + nlen].decode("latin1")
        base = os.path.basename(name.replace("\\", "/"))
        # Only the ne_pac4 model members; skip dir entries and app scaffolding.
        if not base or "ne_pac4" not in name or name.endswith(("/", "\\")):
            continue
        start = j + 30 + nlen + elen
        blob = data[start:start + csize]
        try:
            raw = zlib.decompress(blob, -15) if method == 8 else blob
        except zlib.error as e:
            print(f"  ! failed {base}: {e}", file=sys.stderr)
            continue
        open(os.path.join(OUTDIR, base), "wb").write(raw)
        got += 1
    print(f"extracted {got} ne_pac4 members -> {OUTDIR}")
    if got:
        for f in sorted(os.listdir(OUTDIR)):
            print(f"   {os.path.getsize(os.path.join(OUTDIR, f)):>9}  {f}")


if __name__ == "__main__":
    download()
    extract()
