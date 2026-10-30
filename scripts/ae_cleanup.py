#!/usr/bin/env python3
"""Collect interrupted publications while preserving every complete version."""
from contextlib import closing, contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import time
import uuid

from ae_backup import checksum, git, private_path, require
from ae_publish import sync_dir

PARTIAL = re.compile(r"^\.publishing-(?:[0-9a-f]{12}-)?[a-z0-9_]{8}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
PRESERVE = {"promoted_generations": "all", "rejected_attempts": "all", "audit": "all"}
JOB_TERMINAL = {"completed", "rejected", "cancelled", "rolled_back"}
DEPLOYMENT_TERMINAL = {"completed", "rejected", "rolled_back"}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


@contextmanager
def publication_guard(root):
    descriptor = os.open(root / "publication.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode) and os.fstat(descriptor).st_nlink == 1,
            "invalid publication lock")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise ValueError("publication is in progress") from error
        yield
    finally:
        os.close(descriptor)


def control(database, name):
    row = database.execute("SELECT data FROM control WHERE name=?", (name,)).fetchone()
    return json.loads(row[0]) if row else None


def references(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key == "digest":
                require(isinstance(item, str) and HEX64.fullmatch(item), "invalid retained artifact reference")
                yield item
            else:
                yield from references(item)
    elif isinstance(value, list):
        for item in value:
            yield from references(item)


def inspect(database, root):
    require(control(database, "retention_policy") == PRESERVE, "explicit preservation policy is required")
    recovery = control(database, "restore")
    require(not recovery or recovery.get("pending") is False, "restore recovery is unfinished")
    pinned = set()
    for table, terminal in (("evolution_jobs", JOB_TERMINAL), ("deployments", DEPLOYMENT_TERMINAL)):
        for status, encoded in database.execute(f"SELECT status,data FROM {table}"):
            record = json.loads(encoded)
            require(record["status"] == status and status in terminal, "job recovery is unfinished")
            pinned.update(references(record))
    for table in ("routing", "artifacts", "checkpoints"):
        for (encoded,) in database.execute(f"SELECT data FROM {table}"):
            pinned.update(references(json.loads(encoded)))
    pinned.update(references(control(database, "last_known_good")))
    refs = {}
    for line in git(root / "source.git", "for-each-ref", "--format=%(refname) %(objectname)",
                    "refs/generations/", "refs/attempts/").splitlines():
        name, revision = line.split(" ")
        refs[name] = revision
    retained = {path.name for path in (root / "artifacts").iterdir() if HEX64.fullmatch(path.name)}
    require(pinned and pinned <= retained, "pinned executable is missing")
    for digest in sorted(pinned):
        directory = root / "artifacts" / digest
        require(directory.is_dir() and not directory.is_symlink(), "invalid pinned artifact")
        for name in ("seed", "manifest.json"):
            info = (directory / name).lstat()
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "invalid pinned release file")
        require((directory / "manifest.json").stat().st_size <= 65536, "oversized pinned manifest")
        manifest = json.loads((directory / "manifest.json").read_bytes())
        require(manifest["digest"] == digest and checksum(directory / "seed") == digest,
            "pinned executable digest mismatch")
        require(refs.get("refs/generations/" + digest) == manifest["source_revision"],
            "pinned source reference mismatch")
    return {"pinned_artifacts": sorted(pinned), "preserved_complete_artifacts": len(retained),
        "preserved_source_refs": len(refs)}


def partial(root, name):
    require(isinstance(name, str) and PARTIAL.fullmatch(name), "invalid partial publication name")
    path = root / "artifacts" / name
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False  # An interrupted cleanup may already have removed this one.
    require(stat.S_ISDIR(info.st_mode) and info.st_dev == root.stat().st_dev
        and info.st_uid == os.getuid(), "invalid partial publication directory")
    for item in path.iterdir():
        info = item.lstat()
        require(item.name in ("seed", "manifest.json") and stat.S_ISREG(info.st_mode)
            and info.st_nlink == 1 and info.st_dev == path.stat().st_dev and info.st_uid == os.getuid(),
            "unknown partial publication contents")
    return True


def persist(database, record, kind):
    # Commit intent before deleting filesystem output, and completion only after
    # fsync. On SIGKILL the next invocation resumes the exact recorded names.
    with database:
        database.execute("INSERT OR REPLACE INTO control(name,data) VALUES('storage_cleanup',?)", (canonical(record),))
        database.execute("INSERT INTO events(kind,data) VALUES(?,?)", (kind, canonical(record)))


def cleanup(data_root, apply=False):
    root = private_path(data_root)
    for name in ("artifacts", "source.git", "state"):
        require((root / name).is_dir() and not (root / name).is_symlink(), "invalid persistent storage")
    path = root / "state/agent.sqlite3"
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "invalid state database")
    with publication_guard(root), closing(sqlite3.connect(path.as_uri() + "?mode=rw", uri=True, timeout=1)) as database:
        database.execute("PRAGMA trusted_schema=OFF")
        database.execute("PRAGMA synchronous=FULL")
        report = inspect(database, root)
        previous = control(database, "storage_cleanup")
        pending = previous if previous and previous.get("status") == "pending" else None
        if pending:
            names = pending["publications"]
            require(isinstance(names, list) and len(names) == len(set(names)), "invalid cleanup recovery intent")
        else:
            names = sorted(p.name for p in (root / "artifacts").iterdir() if p.name.startswith(".publishing-"))
        # Validate the whole selection before recording intent or deleting any file.
        existing = [name for name in names if partial(root, name)]
        report.update({"apply": apply, "publications": names, "remaining_publications": existing,
            "resuming": pending is not None})
        if not apply or not names:
            return report
        intent = pending or {"id": uuid.uuid4().hex, "status": "pending", "publications": names,
            "started_at_ms": time.time_ns() // 1_000_000}
        if not pending:
            persist(database, intent, "storage_cleanup_started")
        for name in existing:
            shutil.rmtree(root / "artifacts" / name)
        sync_dir(root / "artifacts")
        completed = {**intent, "status": "completed", "completed_at_ms": time.time_ns() // 1_000_000}
        persist(database, completed, "storage_cleanup_completed")
        return {**report, "cleanup_id": intent["id"], "remaining_publications": []}
