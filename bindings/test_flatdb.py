"""Smoke test for the flat-store Python bindings (bindings/flatdb.py).

Run after building the lib:
    zig build lib && python3 bindings/test_flatdb.py
"""

import tempfile
from pathlib import Path

from flatdb import FlatDB


def k(i: int) -> bytes:
    return i.to_bytes(32, "big")


def v(i: int) -> bytes:
    return (i * 7 + 1).to_bytes(32, "big")


def main() -> None:
    with tempfile.TemporaryDirectory() as d:
        path = str(Path(d) / "store")

        # ── basic put/get, batched get, delete, tombstone ───────────────────────
        with FlatDB(path, prefix_bits=8, freeze_interval=1) as db:
            for i in range(50):
                db.put(k(i), v(i))
            assert db.get(k(0)) == v(0)
            assert db.get(k(49)) == v(49)
            assert db.get(k(999)) is None

            got = db.get_many([k(0), k(25), k(999), k(49)])
            assert got == [v(0), v(25), None, v(49)], got

            db.delete(k(10))
            assert db.get(k(10)) is None
            db.put(k(10), v(123))  # re-insert
            assert db.get(k(10)) == v(123)
            db.delete(k(10))       # delete again, for the persistence check below

            # Freeze into a run (durable), then compact into the base.
            db.end_block(1)
            assert db.covered_height() == 1
            db.compact()
            assert db.get(k(0)) == v(0)        # served from base after compaction
            assert db.get(k(10)) is None       # tombstone dropped the key

        # ── reopen: base + tombstones must survive, deleted key not resurrected ──
        with FlatDB(path, prefix_bits=8, freeze_interval=1) as db:
            assert db.covered_height() == 1
            for i in range(50):
                if i == 10:
                    assert db.get(k(i)) is None, "deleted key resurrected!"
                else:
                    assert db.get(k(i)) == v(i)
            # batched re-read of everything
            got = db.get_many([k(i) for i in range(50)])
            for i in range(50):
                assert got[i] == (None if i == 10 else v(i))

        # ── budgeted compaction step status ─────────────────────────────────────
        with FlatDB(path, prefix_bits=8, memtable_cap=10**9, l0_threshold=100, freeze_interval=1) as db:
            for i in range(100, 160):
                db.put(k(i), v(i))
            db.freeze(2)
            for i in range(160, 220):
                db.put(k(i), v(i))
            db.freeze(3)
            # tiny budget ⇒ at least one in-progress step before done
            saw_in_progress = False
            while True:
                st = db.compact_step(2 * 64)
                if st == "in_progress":
                    saw_in_progress = True
                if st != "in_progress":
                    break
            assert saw_in_progress
            assert db.get(k(150)) == v(150)
            assert db.get(k(210)) == v(210)

    # ── commitments: attach / auto-mark / commit / checkpoint / restore ──────────
    with tempfile.TemporaryDirectory() as d:
        path = str(Path(d) / "store")

        with FlatDB(path, prefix_bits=8, freeze_interval=1) as db:
            assert db.commit_height() == -1          # not attached yet
            assert db.commit_attach(heap_depth=6) == "fresh"
            root_empty = db.commit_root()
            assert root_empty == b"\x00" * 32        # empty mapping ⇒ ZERO root

            for i in range(30):
                db.put(k(i), v(i))                   # auto-marks dirty units
            db.end_block(1)
            root1 = db.commit_block(1)
            assert root1 != root_empty

            # Same mapping ⇒ same root, regardless of storage movement.
            db.compact()
            db.mark_dirty(k(0))                      # force a recompute of a unit
            assert db.commit_block(1) == root1

            # Overwrite + delete change the root; deleting restores nothing silently.
            db.put(k(5), v(999))
            db.delete(k(7))
            db.end_block(2)
            root2 = db.commit_block(2)
            assert root2 != root1
            assert db.commit_height() == 2

            db.commit_checkpoint()

        # Reopen: checkpoint restores the root with no replay (heights match).
        with FlatDB(path, prefix_bits=8, freeze_interval=1) as db:
            assert db.covered_height() == 2
            assert db.commit_attach(heap_depth=6) == "restored"
            assert db.commit_height() == 2
            assert db.commit_root() == root2

            # H mismatch on a second handle-level attach is rejected.
            try:
                db.commit_attach(heap_depth=7)
                raise AssertionError("double attach should fail")
            except RuntimeError:
                pass

            # A cold rebuild from the store agrees with the restored checkpoint.
            assert db.commit_rebuild(2) == root2

    print("OK — flatdb bindings: put/get/get_many/delete/tombstone/freeze/compact/reopen/"
          "budgeted-step/commit-attach/commit-block/checkpoint-restore/rebuild")


if __name__ == "__main__":
    main()
