"""Pytest suite for the PrefixDB Python bindings.

Keys and values are always exactly 32 bytes (Ethereum hash size).
Shorter inputs are zero-padded to 32 bytes by the binding.
"""

import pytest
from bindings.prefixdb import PrefixDB

# ── helpers ──────────────────────────────────────────────────────────────────

def key(n: int) -> bytes:
    """Deterministic 32-byte key from an integer."""
    return n.to_bytes(32, "big")


def val(n: int) -> bytes:
    """Deterministic 32-byte value from an integer."""
    return (n + 0xDEAD).to_bytes(32, "big")


# ── fixtures ─────────────────────────────────────────────────────────────────

@pytest.fixture()
def db():
    with PrefixDB() as instance:
        yield instance


# ── lifecycle ─────────────────────────────────────────────────────────────────

class TestLifecycle:
    def test_open_close(self):
        db = PrefixDB()
        db.close()

    def test_context_manager(self):
        with PrefixDB() as db:
            assert db._handle is not None
        assert db._handle is None

    def test_double_close_is_safe(self):
        db = PrefixDB()
        db.close()
        db.close()  # must not crash


# ── put / get ─────────────────────────────────────────────────────────────────

class TestPutGet:
    def test_put_and_get_exact_32_bytes(self, db):
        k = key(1)
        v = val(1)
        db.put(k, v)
        assert db.get(k) == v

    def test_get_missing_key_returns_none(self, db):
        assert db.get(key(999)) is None

    def test_put_short_key_zero_padded(self, db):
        # Binding zero-pads to 32 bytes; lookup with the same short key must work
        db.put(b"short_key", b"short_val")
        result = db.get(b"short_key")
        assert result is not None
        assert result == b"short_val" + b"\x00" * (32 - len(b"short_val"))

    def test_put_overwrites_previous_value(self, db):
        k = key(2)
        db.put(k, val(10))
        db.put(k, val(20))
        assert db.get(k) == val(20)

    def test_multiple_distinct_keys(self, db):
        pairs = {key(i): val(i) for i in range(10)}
        for k, v in pairs.items():
            db.put(k, v)
        for k, v in pairs.items():
            assert db.get(k) == v

    def test_get_returns_full_32_bytes(self, db):
        k = key(42)
        v = val(42)
        db.put(k, v)
        result = db.get(k)
        assert result is not None
        assert len(result) == 32

    def test_all_zero_key(self, db):
        k = b"\x00" * 32
        v = val(0)
        db.put(k, v)
        assert db.get(k) == v

    def test_all_zero_value(self, db):
        k = key(7)
        v = b"\x00" * 32
        db.put(k, v)
        assert db.get(k) == v

    def test_max_key_and_value(self, db):
        k = b"\xff" * 32
        v = b"\xfe" * 32  # not the internal tombstone (0xFF*32)
        db.put(k, v)
        assert db.get(k) == v


# ── delete ────────────────────────────────────────────────────────────────────

class TestDelete:
    def test_delete_existing_key(self, db):
        k = key(3)
        db.put(k, val(3))
        db.delete(k)
        assert db.get(k) is None

    def test_delete_missing_key_is_noop(self, db):
        db.delete(key(404))  # must not raise

    def test_delete_does_not_affect_other_keys(self, db):
        k1, k2 = key(10), key(11)
        db.put(k1, val(10))
        db.put(k2, val(11))
        db.delete(k1)
        assert db.get(k1) is None
        assert db.get(k2) == val(11)

    def test_put_after_delete_restores_key(self, db):
        k = key(5)
        db.put(k, val(5))
        db.delete(k)
        db.put(k, val(50))
        assert db.get(k) == val(50)

    def test_double_delete(self, db):
        k = key(6)
        db.put(k, val(6))
        db.delete(k)
        db.delete(k)  # second delete must not raise
        assert db.get(k) is None


# ── compaction ───────────────────────────────────────────────────────

class TestCompact:
    def test_compact_empty_db(self, db):
        db.compact()  # must not raise

    def test_data_readable_after_compact(self, db):
        pairs = {key(i): val(i) for i in range(20)}
        for k, v in pairs.items():
            db.put(k, v)
        db.compact()
        for k, v in pairs.items():
            assert db.get(k) == v

    def test_deletes_visible_after_compact(self, db):
        k = key(99)
        db.put(k, val(99))
        db.compact()
        db.delete(k)
        db.compact()
        assert db.get(k) is None

    def test_multiple_compacts(self, db):
        for batch in range(3):
            for i in range(10):
                db.put(key(batch * 10 + i), val(batch * 10 + i))
            db.compact()

        for i in range(30):
            assert db.get(key(i)) == val(i)

    def test_overwrite_survives_compact(self, db):
        k = key(77)
        db.put(k, val(1))
        db.compact()
        db.put(k, val(2))
        db.compact()
        assert db.get(k) == val(2)


# ── validation ────────────────────────────────────────────────────────────────

class TestValidation:
    def test_key_too_long_raises(self, db):
        with pytest.raises(ValueError):
            db.put(b"k" * 33, val(0))

    def test_value_too_long_raises(self, db):
        with pytest.raises(ValueError):
            db.put(key(0), b"v" * 33)

    def test_get_key_too_long_raises(self, db):
        with pytest.raises(ValueError):
            db.get(b"k" * 33)

    def test_delete_key_too_long_raises(self, db):
        with pytest.raises(ValueError):
            db.delete(b"k" * 33)
