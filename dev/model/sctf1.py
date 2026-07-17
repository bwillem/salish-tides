"""SCTF1 — the Salish Tides current-field binary format (shared reader/writer).

Single source of truth for every dev-side script that touches a `.b1` asset
(b1_pack_grid.py, webtide_pack.py, b1_verify_pack.py). The Swift decoder in
SalishTides/CurrentModel/OfflineCurrentModel.swift parses this exact layout and
MUST stay in lockstep — never change the format here without changing it there
(and vice versa).

Byte layout (everything little-endian, no padding, no trailer):

  offset  field
  ------  -----
  0       magic: 5 bytes b"SCTF1"
  5       rows UInt16, cols UInt16
  9       lat0, lon0, dLat, dLon: 4 x Float64
  41      nConst UInt8
  42      per constituent: nameLen UInt8 + name (ASCII, nameLen bytes)
  ...     presence bitmap: ceil(rows*cols / 8) bytes. Row-major cell index
          i = row*cols + col; LSB-first within each byte, i.e.
          bit_i = bytes[i >> 3] >> (i & 7) & 1; 1 = water node present.
  ...     per PRESENT cell, in row-major order:
          uMean Float32, vMean Float32,
          then per constituent (in header order):
          uAmp, uPhase, vAmp, vPhase: 4 x Float32 (phases in degrees)

Grid geometry: cell (row, col) sits at lat = lat0 + row*dLat,
lon = lon0 + col*dLon. Velocities are geographic east/north, m/s.
A file contains exactly the bytes above; `read` asserts full consumption.
"""
import struct
from dataclasses import dataclass

import numpy as np

MAGIC = b"SCTF1"


@dataclass
class Grid:
    """A decoded (or to-be-encoded) SCTF1 grid.

    present: bool[rows*cols], row-major presence mask.
    coeffs:  float32[nPresent, 2 + 4*len(names)] — one row per present cell in
             row-major order: uMean, vMean, then (uAmp, uPhase, vAmp, vPhase)
             per constituent.
    """
    rows: int
    cols: int
    lat0: float
    lon0: float
    dLat: float
    dLon: float
    names: list
    present: np.ndarray
    coeffs: np.ndarray

    @property
    def rec(self):
        """Float32 fields per present cell."""
        return 2 + 4 * len(self.names)

    def latlon(self):
        """(lat[N], lon[N]) of the present cells, in coeffs order."""
        idx = np.flatnonzero(self.present)
        r, c = np.divmod(idx, self.cols)
        return self.lat0 + r * self.dLat, self.lon0 + c * self.dLon


def decode(buf):
    """Parse SCTF1 bytes → Grid. Asserts the buffer is exactly one grid."""
    assert buf[:5] == MAGIC, "bad magic (not an SCTF1 file)"
    rows, cols = struct.unpack_from("<HH", buf, 5)
    lat0, lon0, dLat, dLon = struct.unpack_from("<dddd", buf, 9)
    o = 41
    (n_const,) = struct.unpack_from("<B", buf, o); o += 1
    names = []
    for _ in range(n_const):
        (ln,) = struct.unpack_from("<B", buf, o); o += 1
        names.append(buf[o:o + ln].decode("ascii")); o += ln

    ncell = rows * cols
    nbytes = (ncell + 7) // 8
    present = np.unpackbits(
        np.frombuffer(buf, np.uint8, nbytes, o), bitorder="little",
    )[:ncell].astype(bool)
    o += nbytes

    rec = 2 + 4 * n_const
    npres = int(present.sum())
    coeffs = np.frombuffer(buf, "<f4", npres * rec, o).reshape(npres, rec).copy()
    o += npres * rec * 4
    assert o == len(buf), f"trailing bytes: consumed {o} of {len(buf)}"
    return Grid(rows, cols, lat0, lon0, dLat, dLon, names, present, coeffs)


def read(path):
    """Read an SCTF1 file → Grid."""
    with open(path, "rb") as f:
        return decode(f.read())


def encode(grid):
    """Grid → SCTF1 bytes (the exact on-disk representation)."""
    ncell = grid.rows * grid.cols
    present = np.asarray(grid.present, bool).ravel()
    assert present.size == ncell, "presence mask size != rows*cols"
    coeffs = np.ascontiguousarray(grid.coeffs, dtype="<f4")
    assert coeffs.shape == (int(present.sum()), grid.rec), \
        f"coeffs shape {coeffs.shape} != ({int(present.sum())}, {grid.rec})"
    assert grid.rows <= 0xFFFF and grid.cols <= 0xFFFF, "grid exceeds UInt16 header"

    parts = [MAGIC,
             struct.pack("<HH", grid.rows, grid.cols),
             struct.pack("<dddd", grid.lat0, grid.lon0, grid.dLat, grid.dLon),
             struct.pack("<B", len(grid.names))]
    for name in grid.names:
        b = name.encode("ascii")
        parts.append(struct.pack("<B", len(b)) + b)
    parts.append(np.packbits(present, bitorder="little").tobytes())
    parts.append(coeffs.tobytes())
    return b"".join(parts)


def write(path, grid):
    """Write a Grid as an SCTF1 file; returns the byte size written."""
    blob = encode(grid)
    with open(path, "wb") as f:
        f.write(blob)
    return len(blob)
