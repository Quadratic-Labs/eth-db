"""Python bindings for the flat KV store (src/flat_store.zig).

This is the redesigned, disk-backed engine: io_uring-batched windowed reads over a
prefix-partitioned base, an in-RAM L0 of immutable sorted runs, streaming compaction,
and native tombstones. It is *parallel* to prefixdb.py (the legacy tree engine) and
loads the same shared library.

Keys and values are bytes of at most 32 bytes; shorter inputs are zero-padded on the
right. The store is always disk-backed (a directory path).

Build the shared library first:
    zig build lib          # outputs zig-out/lib/libprefixdb.so

Basic usage:
    from bindings.flatdb import FlatDB

    with FlatDB("/tmp/mydb", prefix_bits=16) as db:
        db.put(b"key", b"value")
        print(db.get(b"key"))            # b'value\\x00...'
        print(db.get_many([b"key", b"x"]))  # [b'value\\x00...', None]
        db.delete(b"key")
        db.end_block(1)                  # block-aligned freeze
        db.compact()

Durability note: writes live in RAM (memtable) until a freeze persists them as a run.
`end_block(height)`/`freeze(height)` are the freeze triggers; `covered_height()` is the
block height the durable state reflects (the host replays newer blocks after reopen).
"""

import ctypes as c
from pathlib import Path

_here = Path(__file__).parent
_lib_path = _here.parent / "zig-out" / "lib" / "libprefixdb.so"

if not _lib_path.exists():
    raise ImportError(
        f"libprefixdb.so not found at {_lib_path}\n"
        "Build it first with: zig build lib"
    )

_lib = c.CDLL(str(_lib_path))

_Buf32 = c.c_ubyte * 32

_lib.flatdb_open.restype = c.c_void_p
_lib.flatdb_open.argtypes = [c.c_char_p, c.c_uint8, c.c_uint64, c.c_uint32, c.c_uint64, c.c_uint8]
_lib.flatdb_deinit.restype = None
_lib.flatdb_deinit.argtypes = [c.c_void_p]
_lib.flatdb_put.restype = c.c_int
_lib.flatdb_put.argtypes = [c.c_void_p, _Buf32, _Buf32]
_lib.flatdb_get.restype = c.c_int
_lib.flatdb_get.argtypes = [c.c_void_p, _Buf32, _Buf32]
_lib.flatdb_get_many.restype = c.c_int
_lib.flatdb_get_many.argtypes = [c.c_void_p, c.POINTER(_Buf32), c.c_size_t, c.POINTER(_Buf32), c.POINTER(c.c_ubyte)]
_lib.flatdb_del.restype = c.c_int
_lib.flatdb_del.argtypes = [c.c_void_p, _Buf32]
_lib.flatdb_prefetch.restype = c.c_int
_lib.flatdb_prefetch.argtypes = [c.c_void_p, c.POINTER(_Buf32), c.c_size_t]
_lib.flatdb_end_block.restype = c.c_int
_lib.flatdb_end_block.argtypes = [c.c_void_p, c.c_uint64]
_lib.flatdb_freeze.restype = c.c_int
_lib.flatdb_freeze.argtypes = [c.c_void_p, c.c_uint64]
_lib.flatdb_compact.restype = c.c_int
_lib.flatdb_compact.argtypes = [c.c_void_p]
_lib.flatdb_compact_step.restype = c.c_int
_lib.flatdb_compact_step.argtypes = [c.c_void_p, c.c_uint64]
_lib.flatdb_compaction_due.restype = c.c_int
_lib.flatdb_compaction_due.argtypes = [c.c_void_p]
_lib.flatdb_covered_height.restype = c.c_uint64
_lib.flatdb_covered_height.argtypes = [c.c_void_p]

_STEP = {0: "idle", 1: "in_progress", 2: "done"}


def _buf32(b: bytes) -> "_Buf32":
    if len(b) > 32:
        raise ValueError(f"key/value must be ≤32 bytes, got {len(b)}")
    return _Buf32(*b.ljust(32, b"\x00"))


class FlatDB:
    """Disk-backed flat KV store. Use as a context manager for safe cleanup.

    Args:
        path:            Directory for the store's files (created if absent). If a
                         manifest is present it is recovered; otherwise a fresh empty
                         store is created.
        prefix_bits:     Partition prefix width (1..32). Only used when creating fresh;
                         on recovery it comes from the manifest. Default 16.
        memtable_cap:    Unique keys before a freeze is due (0 → engine default).
        l0_threshold:    Frozen L0 runs before compaction is due (0 → engine default).
        freeze_interval: Blocks between freezes (0 → engine default).
    """

    def __init__(self, path, prefix_bits: int = 16, memtable_cap: int = 0,
                 l0_threshold: int = 0, freeze_interval: int = 0,
                 o_direct: bool = False) -> None:
        self._handle = _lib.flatdb_open(str(path).encode(), prefix_bits,
                                        memtable_cap, l0_threshold, freeze_interval,
                                        1 if o_direct else 0)
        if not self._handle:
            raise RuntimeError(f"flatdb_open failed for path {path!r} (o_direct={o_direct})")

    # ── lifecycle ────────────────────────────────────────────────────────────────

    def close(self) -> None:
        if self._handle:
            _lib.flatdb_deinit(self._handle)
            self._handle = None

    def __enter__(self) -> "FlatDB":
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    # ── operations ─────────────────────────────────────────────────────────────────

    def put(self, key: bytes, value: bytes) -> None:
        """Store key→value (both zero-padded to 32 bytes)."""
        rc = _lib.flatdb_put(self._handle, _buf32(key), _buf32(value))
        if rc != 0:
            raise RuntimeError(f"put failed (rc={rc})")

    def get(self, key: bytes) -> bytes | None:
        """Return the 32-byte value for key, or None if absent / deleted."""
        out = _Buf32()
        rc = _lib.flatdb_get(self._handle, _buf32(key), out)
        if rc == 0:
            return bytes(out)
        if rc == 1:
            return None
        raise RuntimeError(f"get failed (rc={rc})")

    def get_many(self, keys: list[bytes]) -> list[bytes | None]:
        """Batched lookup — issued as one io_uring read batch. Returns a list aligned
        with `keys`, each element the 32-byte value or None."""
        n = len(keys)
        if n == 0:
            return []
        karr = (_Buf32 * n)(*[_buf32(k) for k in keys])
        varr = (_Buf32 * n)()
        farr = (c.c_ubyte * n)()
        rc = _lib.flatdb_get_many(self._handle, karr, n, varr, farr)
        if rc != 0:
            raise RuntimeError(f"get_many failed (rc={rc})")
        return [bytes(varr[i]) if farr[i] else None for i in range(n)]

    def delete(self, key: bytes) -> None:
        """Delete key (records a tombstone)."""
        rc = _lib.flatdb_del(self._handle, _buf32(key))
        if rc != 0:
            raise RuntimeError(f"delete failed (rc={rc})")

    def prefetch(self, keys: list[bytes]) -> None:
        """Prefetch a block's read set (BAL) into the in-RAM map in one io_uring batch;
        subsequent get/get_many for these keys then avoid per-read disk I/O. Writes
        during the block still take precedence (read-your-writes)."""
        n = len(keys)
        if n == 0:
            return
        karr = (_Buf32 * n)(*[_buf32(k) for k in keys])
        rc = _lib.flatdb_prefetch(self._handle, karr, n)
        if rc != 0:
            raise RuntimeError(f"prefetch failed (rc={rc})")

    def end_block(self, height: int) -> None:
        """Signal end of block `height`; freezes the memtable if a freeze is due."""
        rc = _lib.flatdb_end_block(self._handle, height)
        if rc != 0:
            raise RuntimeError(f"end_block failed (rc={rc})")

    def freeze(self, height: int) -> None:
        """Force-freeze the memtable into a run covering `height`."""
        rc = _lib.flatdb_freeze(self._handle, height)
        if rc != 0:
            raise RuntimeError(f"freeze failed (rc={rc})")

    def compact(self) -> None:
        """Run compaction to completion (fold all L0 runs into the base)."""
        rc = _lib.flatdb_compact(self._handle)
        if rc != 0:
            raise RuntimeError(f"compact failed (rc={rc})")

    def compact_step(self, byte_budget: int) -> str:
        """Advance compaction by ≤ `byte_budget` output bytes. Returns 'idle',
        'in_progress', or 'done'."""
        rc = _lib.flatdb_compact_step(self._handle, byte_budget)
        if rc < 0:
            raise RuntimeError(f"compact_step failed (rc={rc})")
        return _STEP[rc]

    def compaction_due(self) -> bool:
        """True if a compaction is in progress or L0 has reached the threshold."""
        return _lib.flatdb_compaction_due(self._handle) == 1

    def covered_height(self) -> int:
        """Block height the durable state reflects; replay blocks above it after open."""
        return _lib.flatdb_covered_height(self._handle)
