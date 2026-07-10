"""Smoke test for the two-tier bindings (bindings/twotier.py).

Run after building the lib:
    zig build lib && python3 bindings/test_twotier.py
"""

import tempfile
from pathlib import Path

from twotier import TwoTierDB


def a(i: int) -> bytes:
    return ((i * 0x9E3779B97F4A7C15 + 0x1234) % (1 << 64)).to_bytes(8, "big") + b"\x00" * 24


def s(i: int) -> bytes:
    return ((i * 0xC2B2AE3D27D4EB4F + 0x77) % (1 << 64)).to_bytes(8, "big") + b"\x00" * 24


def v(i: int) -> bytes:
    return (i * 7 + 1).to_bytes(32, "big")


def main() -> None:
    with tempfile.TemporaryDirectory() as d:
        path = str(Path(d) / "state")
        args = dict(prefix_bits=4, fence_gap=8, freeze_interval=1,
                    acct_heap_depth=4, t_big_log2=3)  # T_big = 8

        with TwoTierDB(path, **args) as db:
            assert db.root() == b"\x00" * 32          # empty mapping ⇒ ZERO root
            assert db.storage_root(a(1)) is None

            # Account 1 gets 20 slots (→ promoted past T_big), account 2 gets 2.
            for i in range(20):
                db.put_slot(a(1), s(i), v(i))
            for i in range(2):
                db.put_slot(a(2), s(i), v(100 + i))
            db.end_block(1)
            root1 = db.commit_block(1)
            assert root1 != b"\x00" * 32
            assert db.big_count() == 1                 # the 20-slot account promoted
            assert db.get_slot(a(1), s(3)) == v(3)
            assert db.get_slot(a(1), s(999)) is None
            assert db.storage_root(a(1)) is not None
            assert db.storage_root(a(2)) is not None

            # Same mapping after compaction ⇒ same root.
            db.compact()
            db.mark_dirty_slot(a(1), s(0))             # force a unit recompute
            assert db.commit_block(1) == root1

            # Emptying account 2 removes its account record entirely.
            for i in range(2):
                db.delete_slot(a(2), s(i))
            db.end_block(2)
            root2 = db.commit_block(2)
            assert root2 != root1
            assert db.storage_root(a(2)) is None
            assert db.commit_height() == 2

            db.checkpoint()

        # Reopen: commitment state (incl. the big-account row) restores; no replay
        # needed since checkpoint height == covered height.
        with TwoTierDB(path, **args) as db:
            assert db.covered_height() == 2
            assert db.commit_height() == 2
            assert db.root() == root2
            assert db.big_count() == 1
            assert db.get_slot(a(1), s(7)) == v(7)

            # Write past the checkpoint, commit, reopen without checkpointing:
            # replay via mark_dirty_slot converges to the same root.
            db.put_slot(a(1), s(500), v(500))
            db.end_block(3)
            root3 = db.commit_block(3)
            assert root3 != root2

        with TwoTierDB(path, **args) as db:
            assert db.commit_height() == 2             # checkpoint is older than data
            assert db.covered_height() == 3
            db.mark_dirty_slot(a(1), s(500))            # replay block 3's write set
            assert db.commit_block(3) == root3

    print("OK — twotier bindings: put/get/delete/promote/storage_root/empty-account/"
          "commit/checkpoint-restore/replay")


if __name__ == "__main__":
    main()
