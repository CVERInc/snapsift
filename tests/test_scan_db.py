"""iter_assets against a real (minimal) Photos.sqlite schema.

Pins the protection contract at the SQL layer: the `edited` flag MUST be read
from ZASSET.ZADJUSTMENTSSTATE and travel into groups.json — pick.py's
"never delete an edited frame" promise is only as real as this query.
"""
import sqlite3

from dataclasses import asdict

from scan import iter_assets


def make_db():
    conn = sqlite3.connect(":memory:")
    conn.executescript("""
        CREATE TABLE ZASSET (
            Z_PK INTEGER PRIMARY KEY,
            ZUUID TEXT, ZFILENAME TEXT, ZDATECREATED REAL,
            ZWIDTH INTEGER, ZHEIGHT INTEGER,
            ZUNIFORMTYPEIDENTIFIER TEXT, ZKIND INTEGER,
            ZFAVORITE INTEGER, ZADJUSTMENTSSTATE INTEGER,
            ZHIDDEN INTEGER, ZTRASHEDSTATE INTEGER,
            ZHIGHLIGHTVISIBILITYSCORE REAL
        );
        CREATE TABLE ZADDITIONALASSETATTRIBUTES (
            ZASSET INTEGER, ZORIGINALFILENAME TEXT, ZORIGINALFILESIZE INTEGER
        );
        CREATE TABLE ZCOMPUTEDASSETATTRIBUTES (
            ZASSET INTEGER,
            ZSHARPLYFOCUSEDSUBJECTSCORE REAL, ZWELLCHOSENSUBJECTSCORE REAL,
            ZWELLFRAMEDSUBJECTSCORE REAL, ZWELLTIMEDSHOTSCORE REAL,
            ZINTERESTINGSUBJECTSCORE REAL, ZPLEASANTCOMPOSITIONSCORE REAL,
            ZPLEASANTLIGHTINGSCORE REAL, ZFAILURESCORE REAL, ZNOISESCORE REAL
        );
    """)
    return conn


def add_asset(conn, pk, *, uuid, adjustments, favorite=0, taken_at=1000.0):
    conn.execute(
        "INSERT INTO ZASSET (Z_PK, ZUUID, ZFILENAME, ZDATECREATED, ZWIDTH,"
        " ZHEIGHT, ZUNIFORMTYPEIDENTIFIER, ZKIND, ZFAVORITE,"
        " ZADJUSTMENTSSTATE, ZHIDDEN, ZTRASHEDSTATE)"
        " VALUES (?, ?, 'IMG.heic', ?, 4032, 3024, 'public.heic', 0, ?, ?, 0, 0)",
        (pk, uuid, taken_at, favorite, adjustments),
    )


def test_edited_flag_comes_from_adjustments_state():
    conn = make_db()
    add_asset(conn, 1, uuid="pristine", adjustments=0)
    add_asset(conn, 2, uuid="edited",   adjustments=2, taken_at=1001.0)
    # NULL adjustments (row predating the column being populated) must read as
    # NOT edited, never as edited and never crash.
    add_asset(conn, 3, uuid="null-adj", adjustments=None, taken_at=1002.0)

    by_uuid = {p.uuid: p for p in iter_assets(conn)}
    assert by_uuid["pristine"].edited is False
    assert by_uuid["edited"].edited is True
    assert by_uuid["null-adj"].edited is False


def test_edited_flag_survives_into_groups_json_payload():
    # scan.py serializes via dataclasses.asdict — the key pick.py's
    # is_protected() reads must be present and truthy for an edited frame.
    conn = make_db()
    add_asset(conn, 1, uuid="edited", adjustments=3)
    photo = next(iter_assets(conn))
    payload = asdict(photo)
    assert payload["edited"] is True
