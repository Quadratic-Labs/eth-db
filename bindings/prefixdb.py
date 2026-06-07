"""Python bindings for the PrefixDB engine.

Keys and values are plain bytes objects of at most 32 bytes; shorter inputs
are zero-padded on the right before being stored.

Build the shared library first:
    zig build lib          # outputs zig-out/lib/libprefixdb.so

Basic usage:
    from bindings.prefixdb import PrefixDB

    with PrefixDB() as db:
        db.put(b"key", b"value")
        print(db.get(b"key"))   # b'value\\x00...\\x00'
        db.delete(b"key")
        print(db.get(b"key"))   # None
        db.compact()
"""

import ctypes
from pathlib import Path

_here = Path(__file__).parent
_lib_path = _here.parent / "zig-out" / "lib" / "libprefixdb.so"

if not _lib_path.exists():
    raise ImportError(
        f"libprefixdb.so not found at {_lib_path}\n"
        "Build it first with: zig build lib"
    )

_lib = ctypes.CDLL(str(_lib_path))

_Buf32 = ctypes.c_ubyte * 32

_lib.prefixdb_init.restype = ctypes.c_void_p
_lib.prefixdb_init.argtypes = []

_lib.prefixdb_init_capacity.restype = ctypes.c_void_p
_lib.prefixdb_init_capacity.argtypes = [ctypes.c_uint32, ctypes.c_uint32]

_lib.prefixdb_deinit.restype = None
_lib.prefixdb_deinit.argtypes = [ctypes.c_void_p]

_lib.prefixdb_put.restype = ctypes.c_int
_lib.prefixdb_put.argtypes = [ctypes.c_void_p, _Buf32, _Buf32]

_lib.prefixdb_get.restype = ctypes.c_int
_lib.prefixdb_get.argtypes = [ctypes.c_void_p, _Buf32, _Buf32]

_lib.prefixdb_del.restype = ctypes.c_int
_lib.prefixdb_del.argtypes = [ctypes.c_void_p, _Buf32]

_lib.prefixdb_compact.restype = ctypes.c_int
_lib.prefixdb_compact.argtypes = [ctypes.c_void_p]

_lib.prefixdb_open.restype = ctypes.c_void_p
_lib.prefixdb_open.argtypes = [ctypes.c_char_p, ctypes.c_uint32, ctypes.c_uint32]

_lib.prefixdb_flush.restype = ctypes.c_int
_lib.prefixdb_flush.argtypes = [ctypes.c_void_p]

_lib.prefixdb_estimate_key_count.restype = ctypes.c_int64
_lib.prefixdb_estimate_key_count.argtypes = [ctypes.c_void_p]


class Metrics(ctypes.Structure):
    """Snapshot of internal PrefixDB counters.

    All fields are zero when the library was built without -Denable_metrics=true.

    Useful derived ratios:
      read_amp           = read_sst_loads / read_ops
      filter_selectivity = 1 - append_filter_hits / append_filter_probes
      sst_cache_hit_rate = sst_cache_hits / (sst_cache_hits + sst_cache_misses)
      write_amp          = compaction_sst_writes / write_ops
    """
    _fields_ = [
        ("read_ops",              ctypes.c_uint64),
        ("write_ops",             ctypes.c_uint64),
        ("l0_hits",               ctypes.c_uint64),
        ("read_sst_loads",        ctypes.c_uint64),
        ("read_node_loads",       ctypes.c_uint64),
        ("append_filter_probes",  ctypes.c_uint64),
        ("append_filter_hits",    ctypes.c_uint64),
        ("sst_cache_hits",        ctypes.c_uint64),
        ("sst_cache_misses",      ctypes.c_uint64),
        ("node_cache_hits",       ctypes.c_uint64),
        ("node_cache_misses",     ctypes.c_uint64),
        ("l0_flushes",            ctypes.c_uint64),
        ("compaction_calls",      ctypes.c_uint64),
        ("compaction_ops",        ctypes.c_uint64),
        ("compaction_sst_reads",  ctypes.c_uint64),
        ("compaction_sst_writes", ctypes.c_uint64),
        ("disk_node_reads",         ctypes.c_uint64),
        ("disk_node_writes",        ctypes.c_uint64),
        ("disk_sst_reads",          ctypes.c_uint64),
        ("disk_sst_writes",         ctypes.c_uint64),
        ("commit_block_calls",      ctypes.c_uint64),
        ("commit_nodes_processed",  ctypes.c_uint64),
        ("commit_block_ns",         ctypes.c_uint64),
    ]

    def as_dict(self) -> dict:
        return {name: getattr(self, name) for name, _ in self._fields_}


_lib.prefixdb_commit_block.restype = ctypes.c_int
_lib.prefixdb_commit_block.argtypes = [ctypes.c_void_p, _Buf32]

_lib.prefixdb_get_metrics.restype = ctypes.c_int
_lib.prefixdb_get_metrics.argtypes = [ctypes.c_void_p, ctypes.POINTER(Metrics)]

_lib.prefixdb_reset_metrics.restype = ctypes.c_int
_lib.prefixdb_reset_metrics.argtypes = [ctypes.c_void_p]


def _buf32(b: bytes) -> _Buf32:
    if len(b) > 32:
        raise ValueError(f"key/value must be ≤32 bytes, got {len(b)}")
    return _Buf32(*b.ljust(32, b"\x00"))


class PrefixDB:
    """PrefixDB store, optionally disk-backed. Use as a context manager for safe cleanup.

    Args:
        path:     Directory path for persistent storage. If provided, the database
                  is opened from disk (recovering an existing manifest.bin if present).
                  If None, an in-memory database is created.
        node_cap: LRU capacity for routing-node pages (default: 16384).
        sst_cap:  LRU capacity for SST (key-value) pages (default: 4096).

    Each node page is ~4 KiB; each SST page is 4 KiB × 64 entries.
    Pass both to control how aggressively the engine caches in RAM.
    """

    def __init__(self, path: str | None = None, node_cap: int | None = None, sst_cap: int | None = None) -> None:
        if path is not None:
            nc = node_cap if node_cap is not None else 0
            sc = sst_cap  if sst_cap  is not None else 0
            self._handle = _lib.prefixdb_open(path.encode(), nc, sc)
        elif node_cap is not None or sst_cap is not None:
            nc = node_cap if node_cap is not None else 16384
            sc = sst_cap  if sst_cap  is not None else 4096
            self._handle = _lib.prefixdb_init_capacity(nc, sc)
        else:
            self._handle = _lib.prefixdb_init()
        if not self._handle:
            raise RuntimeError("prefixdb_init failed — out of memory?")

    # ── lifecycle ────────────────────────────────────────────────────────────

    def close(self) -> None:
        if self._handle:
            _lib.prefixdb_deinit(self._handle)
            self._handle = None

    def __enter__(self) -> "PrefixDB":
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    # ── operations ───────────────────────────────────────────────────────────

    def put(self, key: bytes, value: bytes) -> None:
        """Store key→value. Both are zero-padded to 32 bytes."""
        rc = _lib.prefixdb_put(self._handle, _buf32(key), _buf32(value))
        if rc != 0:
            raise RuntimeError(f"put failed (rc={rc})")

    def get(self, key: bytes) -> bytes | None:
        """Return the 32-byte value for key, or None if not found / deleted."""
        value_out = _Buf32()
        rc = _lib.prefixdb_get(self._handle, _buf32(key), value_out)
        if rc == 0:
            return bytes(value_out)
        if rc == 1:
            return None
        raise RuntimeError(f"get failed (rc={rc})")

    def delete(self, key: bytes) -> None:
        """Delete key by writing an internal tombstone."""
        rc = _lib.prefixdb_del(self._handle, _buf32(key))
        if rc != 0:
            raise RuntimeError(f"delete failed (rc={rc})")

    def compact(self) -> None:
        """Drain the compaction queue (merge append→sorted zones, split/merge nodes)."""
        rc = _lib.prefixdb_compact(self._handle)
        if rc != 0:
            raise RuntimeError(f"compaction failed (rc={rc})")

    def commit_block(self) -> bytes:
        """Flush L0, recompute child_commitments for all dirty nodes, return the
        32-byte Merkle root hash for the current state."""
        hash_out = _Buf32()
        rc = _lib.prefixdb_commit_block(self._handle, hash_out)
        if rc != 0:
            raise RuntimeError(f"commit_block failed (rc={rc})")
        return bytes(hash_out)

    def flush(self) -> None:
        """Write manifest to disk. No-op for in-memory databases."""
        rc = _lib.prefixdb_flush(self._handle)
        if rc != 0:
            raise RuntimeError(f"flush failed (rc={rc})")

    def estimate_key_count(self) -> int:
        """Return an estimated upper-bound count of stored keys.

        Reads node page-count metadata only — no SST page loads or disk I/O.
        Overcounts tombstones (deleted keys) and uncompacted duplicate writes.
        Call compact() first for a tighter estimate.
        Returns -1 on internal error.
        """
        return _lib.prefixdb_estimate_key_count(self._handle)

    def get_metrics(self) -> Metrics:
        """Return a snapshot of all internal counters.

        All fields are zero when the library was built without -Denable_metrics=true.
        """
        out = Metrics()
        rc = _lib.prefixdb_get_metrics(self._handle, ctypes.byref(out))
        if rc != 0:
            raise RuntimeError(f"get_metrics failed (rc={rc})")
        return out

    def reset_metrics(self) -> None:
        """Reset all internal counters to zero.

        No-op when the library was built without -Denable_metrics=true.
        """
        rc = _lib.prefixdb_reset_metrics(self._handle)
        if rc != 0:
            raise RuntimeError(f"reset_metrics failed (rc={rc})")
