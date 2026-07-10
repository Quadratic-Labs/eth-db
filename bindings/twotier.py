"""Python bindings for the two-tier state DB (src/two_tier.zig).

State model: `account_hash → {slot_hash → value}` with a canonical binary
commitment — per-account storage subtrees under an account tree (leaf =
Blake3(0x01 ‖ account_hash ‖ storage_root)). The engine owns three objects per
directory: the slots store (64-byte composite keys), the accounts store
(commitment-maintained `account_hash → storage_root`), and the commitment state
(checkpointed as `state.croot` + `state.cstor`). The host only ever speaks
(account, slot, value); all inputs are bytes ≤ 32, zero-padded.

Block cycle:
    db.put_slot(acct, slot, value) / db.delete_slot(acct, slot)   # during block
    db.end_block(h)                                               # freeze trigger
    root = db.commit_block(h)                                     # state root

Recovery: reopen; for blocks above db.commit_height() re-put (above
db.covered_height()) or db.mark_dirty_slot (already durable), then commit once.
Checkpointing is explicit (db.checkpoint()) — close() never writes it.

Build the shared library first:
    zig build lib          # outputs zig-out/lib/libprefixdb.so
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

_lib.ttdb_open.restype = c.c_void_p
_lib.ttdb_open.argtypes = [c.c_char_p, c.c_uint8, c.c_uint32, c.c_uint64, c.c_uint32,
                           c.c_uint64, c.c_uint8, c.c_uint8, c.c_uint8]
_lib.ttdb_deinit.restype = None
_lib.ttdb_deinit.argtypes = [c.c_void_p]
_lib.ttdb_put_slot.restype = c.c_int
_lib.ttdb_put_slot.argtypes = [c.c_void_p, _Buf32, _Buf32, _Buf32]
_lib.ttdb_delete_slot.restype = c.c_int
_lib.ttdb_delete_slot.argtypes = [c.c_void_p, _Buf32, _Buf32]
_lib.ttdb_get_slot.restype = c.c_int
_lib.ttdb_get_slot.argtypes = [c.c_void_p, _Buf32, _Buf32, _Buf32]
_lib.ttdb_storage_root.restype = c.c_int
_lib.ttdb_storage_root.argtypes = [c.c_void_p, _Buf32, _Buf32]
_lib.ttdb_mark_dirty_slot.restype = c.c_int
_lib.ttdb_mark_dirty_slot.argtypes = [c.c_void_p, _Buf32, _Buf32]
_lib.ttdb_end_block.restype = c.c_int
_lib.ttdb_end_block.argtypes = [c.c_void_p, c.c_uint64]
_lib.ttdb_commit_block.restype = c.c_int
_lib.ttdb_commit_block.argtypes = [c.c_void_p, c.c_uint64, _Buf32]
_lib.ttdb_root.restype = None
_lib.ttdb_root.argtypes = [c.c_void_p, _Buf32]
_lib.ttdb_committed_height.restype = c.c_uint64
_lib.ttdb_committed_height.argtypes = [c.c_void_p]
_lib.ttdb_covered_height.restype = c.c_uint64
_lib.ttdb_covered_height.argtypes = [c.c_void_p]
_lib.ttdb_checkpoint.restype = c.c_int
_lib.ttdb_checkpoint.argtypes = [c.c_void_p]
_lib.ttdb_compact.restype = c.c_int
_lib.ttdb_compact.argtypes = [c.c_void_p]
_lib.ttdb_compact_step.restype = c.c_int
_lib.ttdb_compact_step.argtypes = [c.c_void_p, c.c_uint64]
_lib.ttdb_compaction_due.restype = c.c_int
_lib.ttdb_compaction_due.argtypes = [c.c_void_p]
_lib.ttdb_big_count.restype = c.c_uint32
_lib.ttdb_big_count.argtypes = [c.c_void_p]

_STEP = {0: "idle", 1: "in_progress", 2: "done"}


def _buf32(b: bytes) -> "_Buf32":
    if len(b) > 32:
        raise ValueError(f"account/slot/value must be ≤32 bytes, got {len(b)}")
    return _Buf32(*b.ljust(32, b"\x00"))


class TwoTierDB:
    """Two-tier state DB (account‖slot keys + binary commitment). Context manager.

    Args mirror FlatDB where they overlap; zeros pick engine defaults:
        prefix_bits:      partition width for both stores (default 16).
        fence_gap:        slots-store fence gap G (mandatory there; default 64).
        acct_heap_depth:  account-tree heap depth H (default 24 → 1 GiB heap RAM;
                          pass smaller for toy databases).
        t_big_log2:       k = log₂ T_big; accounts above 2^k slots get a per-account
                          unit row at depth ⌈log₂ n⌉ − k (default 12).
    """

    def __init__(self, path, prefix_bits: int = 0, fence_gap: int = 0,
                 memtable_cap: int = 0, l0_threshold: int = 0,
                 freeze_interval: int = 0, o_direct: bool = False,
                 acct_heap_depth: int = 0, t_big_log2: int = 0) -> None:
        self._handle = _lib.ttdb_open(str(path).encode(), prefix_bits, fence_gap,
                                      memtable_cap, l0_threshold, freeze_interval,
                                      1 if o_direct else 0, acct_heap_depth, t_big_log2)
        if not self._handle:
            raise RuntimeError(f"ttdb_open failed for path {path!r}")

    # ── lifecycle ────────────────────────────────────────────────────────────────

    def close(self) -> None:
        if self._handle:
            _lib.ttdb_deinit(self._handle)
            self._handle = None

    def __enter__(self) -> "TwoTierDB":
        return self

    def __exit__(self, *_) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    # ── state operations ─────────────────────────────────────────────────────────

    def put_slot(self, acct: bytes, slot: bytes, value: bytes) -> None:
        """Write (acct, slot) → value and mark its commitment units dirty."""
        rc = _lib.ttdb_put_slot(self._handle, _buf32(acct), _buf32(slot), _buf32(value))
        if rc != 0:
            raise RuntimeError(f"put_slot failed (rc={rc})")

    def delete_slot(self, acct: bytes, slot: bytes) -> None:
        rc = _lib.ttdb_delete_slot(self._handle, _buf32(acct), _buf32(slot))
        if rc != 0:
            raise RuntimeError(f"delete_slot failed (rc={rc})")

    def get_slot(self, acct: bytes, slot: bytes) -> bytes | None:
        out = _Buf32()
        rc = _lib.ttdb_get_slot(self._handle, _buf32(acct), _buf32(slot), out)
        if rc == 0:
            return bytes(out)
        if rc == 1:
            return None
        raise RuntimeError(f"get_slot failed (rc={rc})")

    def storage_root(self, acct: bytes) -> bytes | None:
        """The account's storage root as of the last commit; None = no storage."""
        out = _Buf32()
        rc = _lib.ttdb_storage_root(self._handle, _buf32(acct), out)
        if rc == 0:
            return bytes(out)
        if rc == 1:
            return None
        raise RuntimeError(f"storage_root failed (rc={rc})")

    def mark_dirty_slot(self, acct: bytes, slot: bytes) -> None:
        """Mark without writing — replay of blocks the slots store already holds."""
        rc = _lib.ttdb_mark_dirty_slot(self._handle, _buf32(acct), _buf32(slot))
        if rc != 0:
            raise RuntimeError(f"mark_dirty_slot failed (rc={rc})")

    # ── block cycle / commitment ─────────────────────────────────────────────────

    def end_block(self, height: int) -> None:
        rc = _lib.ttdb_end_block(self._handle, height)
        if rc != 0:
            raise RuntimeError(f"end_block failed (rc={rc})")

    def commit_block(self, height: int) -> bytes:
        """Commit block `height` and return the 32-byte state root."""
        out = _Buf32()
        rc = _lib.ttdb_commit_block(self._handle, height, out)
        if rc != 0:
            raise RuntimeError(f"commit_block failed (rc={rc})")
        return bytes(out)

    def root(self) -> bytes:
        out = _Buf32()
        _lib.ttdb_root(self._handle, out)
        return bytes(out)

    def commit_height(self) -> int:
        """Block height the commitment state reflects."""
        return _lib.ttdb_committed_height(self._handle)

    def covered_height(self) -> int:
        """Block height the durable slot data reflects."""
        return _lib.ttdb_covered_height(self._handle)

    def checkpoint(self) -> None:
        """Persist the commitment state (state.croot + state.cstor), atomically."""
        rc = _lib.ttdb_checkpoint(self._handle)
        if rc != 0:
            raise RuntimeError(f"checkpoint failed (rc={rc})")

    # ── maintenance ──────────────────────────────────────────────────────────────

    def compact(self) -> None:
        rc = _lib.ttdb_compact(self._handle)
        if rc != 0:
            raise RuntimeError(f"compact failed (rc={rc})")

    def compact_step(self, byte_budget: int) -> str:
        rc = _lib.ttdb_compact_step(self._handle, byte_budget)
        if rc < 0:
            raise RuntimeError(f"compact_step failed (rc={rc})")
        return _STEP[rc]

    def compaction_due(self) -> bool:
        return _lib.ttdb_compaction_due(self._handle) == 1

    def big_count(self) -> int:
        """Accounts currently above T_big (holding a per-account unit row)."""
        return _lib.ttdb_big_count(self._handle)
