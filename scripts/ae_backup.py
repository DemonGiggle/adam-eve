"""Operator-only, consistent backups of the supported controller data schema.

Backups are trusted private data, not an import format for agent-supplied files.
No executable in a backup is run or rebuilt during copying or verification.
"""
import hashlib
import json
import os
from pathlib import Path
from contextlib import closing
import re
import shutil
import sqlite3
import stat
import subprocess
import tempfile
import time

from ae_publish import publication_lock, sync_dir, sync_tree

HEX64 = re.compile(r"[0-9a-f]{64}\Z")
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
TABLES = {"routing", "events", "turns", "tools", "tool_attempts", "artifacts",
          "checkpoints", "deployments", "control", "evolution_jobs",
          "evolution_proposals", "evolution_llm_calls"}
POLICY_KEYS = {"schedule", "minimum_copies", "rpo_ms", "rto_ms", "failure_domain",
               "disk_reserve_bytes"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode() + b"\n"


def now_ms():
    return time.time_ns() // 1_000_000


def private_path(path, *, create=False):
    path = Path(path).expanduser().absolute()
    # Resolve no symlink component, including a dangling final component.
    for part in (path, *path.parents):
        require(not part.is_symlink(), "symlink in private path")
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.is_dir(), "private directory does not exist")
    require(path.stat().st_uid == os.getuid() and not path.stat().st_mode & 0o077,
            "directory must be operator-owned and private (0700)")
    return path.resolve()


def separate(first, second):
    require(first != second and first not in second.parents and second not in first.parents,
            "source, backup and restore paths must not overlap")


def policy_record(path):
    return validate_policy(json.loads(Path(path).read_bytes()))


def validate_policy(record):
    require(isinstance(record, dict) and set(record) == POLICY_KEYS, "incomplete backup policy")
    for key in ("schedule", "failure_domain"):
        require(isinstance(record[key], str) and 0 < len(record[key].encode()) <= 1024,
                "invalid policy description")
    for key in POLICY_KEYS - {"schedule", "failure_domain"}:
        require(type(record[key]) is int and 0 < record[key] < 2**63, "invalid policy limit")
    return record


def regular_files(root):
    """Never follow links; fail on sockets, devices, or unexpected mounts/links."""
    require(root.is_dir() and not root.is_symlink(), "missing data directory")
    device = root.stat().st_dev
    result = []
    def walk_error(error):
        raise error
    for base, dirs, files in os.walk(root, followlinks=False, onerror=walk_error):
        for name in dirs + files:
            path = Path(base) / name
            info = path.lstat()
            require(info.st_dev == device and (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)),
                    "backup contains a link, special file or another filesystem")
            if name in files:
                require(info.st_nlink == 1, "hard links are not supported in backup data")
                result.append(path)
    return sorted(result)


def checksum(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def reserve(path, count, policy):
    require(shutil.disk_usage(path).free >= count + policy["disk_reserve_bytes"], "disk reserve exhausted")


def copy_regular(source, target, policy):
    info = source.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "only regular independent files can be copied")
    reserve(target.parent, info.st_size, policy)
    # Paths are inside operator-owned directories, protected from agent writes.
    with open(source, "rb") as reader, open(target, "xb") as writer:
        shutil.copyfileobj(reader, writer, 1024 * 1024)
        writer.flush()
        os.fchmod(writer.fileno(), 0o600)
        os.fsync(writer.fileno())


def copy_tree(source, target, policy):
    files = regular_files(source)
    target.mkdir(mode=0o700)
    for path in files:
        destination = target / path.relative_to(source)
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        copy_regular(path, destination, policy)


def connect(path):
    connection = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=5)
    connection.execute("PRAGMA trusted_schema=OFF")
    return connection


def snapshot(source, target, policy):
    started = now_ms()
    deadline = time.monotonic() + 60
    with closing(connect(source)) as reader:
        reader.execute("BEGIN")
        route = json.loads(reader.execute("SELECT data FROM routing WHERE id=1").fetchone()[0])
        seq = reader.execute("SELECT COALESCE(MAX(seq),0) FROM events").fetchone()[0]
        recovery = reader.execute("SELECT data FROM control WHERE name='restore'").fetchone()
        floor = max(route["epoch"], json.loads(recovery[0])["epoch_floor"] if recovery else 0)
        pages = reader.execute("PRAGMA page_count").fetchone()[0]
        size = reader.execute("PRAGMA page_size").fetchone()[0]
        reserve(target.parent, pages * size, policy)
        with closing(sqlite3.connect(target)) as writer:
            def progress(*_):
                require(time.monotonic() < deadline, "SQLite snapshot exceeded deadline")
            reader.backup(writer, pages=256, progress=progress, sleep=0.01)
            writer.execute("PRAGMA journal_mode=DELETE")
            writer.execute("PRAGMA synchronous=FULL")
        reader.rollback()
    return {"routing": route, "event_seq": seq, "epoch_floor": floor, "snapshot_started_at_ms": started}


def git(repo, *args):
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LC_ALL": "C",
                   "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
                   "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0",
                   "GIT_ALLOW_PROTOCOL": "", "GIT_OPTIONAL_LOCKS": "0"}
    result = subprocess.run(["git", "--git-dir", str(repo), "-c", "core.hooksPath=/dev/null",
                             *args], env=environment, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, timeout=30, check=True)
    require(len(result.stdout) <= 65536, "oversized Git metadata")
    return result.stdout.decode().strip()


def manifests(root):
    repo = root / "source.git"
    # No external object stores, grafts, partial clone or worktree dependencies.
    for name in ("objects/info/alternates", "objects/info/http-alternates", "info/grafts",
                 "shallow", "worktrees"):
        require(not (repo / name).exists(), "source repository has external or incomplete dependencies")
    require(not list((repo / "objects").rglob("*.promisor")), "partial source repository")
    git(repo, "fsck", "--strict", "--full", "--no-reflogs", "--no-dangling")
    found = {}
    for directory in sorted((root / "artifacts").iterdir()):
        require(HEX64.fullmatch(directory.name) and directory.is_dir(), "invalid retained artifact directory")
        require({p.name for p in directory.iterdir()} == {"seed", "manifest.json"}, "incomplete retained artifact")
        record = json.loads((directory / "manifest.json").read_bytes())
        require(record["digest"] == directory.name and checksum(directory / "seed") == directory.name,
                "artifact digest mismatch")
        require(HEX40.fullmatch(record["source_revision"]) and HEX40.fullmatch(record["source_tree"]),
                "invalid source identity")
        require(git(repo, "rev-parse", "--verify", "refs/generations/" + directory.name) == record["source_revision"],
                "protected source reference mismatch")
        require(git(repo, "rev-parse", "--verify", record["source_revision"] + "^{tree}") == record["source_tree"],
                "source tree mismatch")
        found[directory.name] = record
    require(found, "no retained artifacts")
    for record in found.values():
        if record.get("parent") is not None:
            parent = found.get(record["parent"])
            require(parent is not None, "retained artifact parent is missing")
            require(git(repo, "rev-parse", "--verify", record["source_revision"] + "^") == parent["source_revision"],
                    "retained source ancestry mismatch")
    return found


def verify_state(root, point):
    retained = manifests(root)
    with closing(connect(root / "state/agent.sqlite3")) as connection:
        require(connection.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "SQLite integrity failure")
        require(not connection.execute("PRAGMA foreign_key_check").fetchall(), "SQLite reference failure")
        tables = {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        require(tables - {"sqlite_sequence"} == TABLES, "unsupported state schema")
        route = json.loads(connection.execute("SELECT data FROM routing WHERE id=1").fetchone()[0])
        seq = connection.execute("SELECT COALESCE(MAX(seq),0) FROM events").fetchone()[0]
        require(route == point["routing"] and seq == point["event_seq"], "snapshot recovery point mismatch")
        recovery = connection.execute("SELECT data FROM control WHERE name='restore'").fetchone()
        floor = max(route["epoch"], json.loads(recovery[0])["epoch_floor"] if recovery else 0)
        require(floor == point["epoch_floor"], "snapshot epoch floor mismatch")
        def references(value):
            if isinstance(value, dict):
                if "digest" in value and "source_revision" in value:
                    require(retained.get(value["digest"]) == value, "state references unavailable artifact")
                for child in value.values():
                    references(child)
            elif isinstance(value, list):
                for child in value:
                    references(child)
        for digest, encoded in connection.execute("SELECT digest,data FROM artifacts"):
            require(retained.get(digest) == json.loads(encoded), "artifact registry mismatch")
        for table in ("routing", "control", "deployments", "evolution_jobs", "checkpoints"):
            for (encoded,) in connection.execute(f"SELECT data FROM {table}"):
                record = json.loads(encoded)
                references(record)
                if table == "checkpoints":
                    require(record["generation"] in retained and record["last_event_seq"] <= seq,
                            "checkpoint outside retained recovery point")
    return retained


def inventory(root):
    return {p.relative_to(root).as_posix(): {"bytes": p.stat().st_size, "sha256": checksum(p)}
            for p in regular_files(root)}


def backup(data_root, backup_root, policy):
    validate_policy(policy)
    source = private_path(data_root)
    for name in ("state", "source.git", "artifacts"):
        require((source / name).is_dir() and not (source / name).is_symlink(), "missing controller data directory")
    database = source / "state/agent.sqlite3"
    require(database.is_file() and not database.is_symlink() and database.stat().st_nlink == 1,
            "missing regular state database")
    destination = private_path(backup_root, create=True)
    separate(source, destination)
    separate(Path(__file__).resolve().parent.parent, destination)
    with publication_lock(source):
        staging = Path(tempfile.mkdtemp(prefix=".backup-", dir=destination))
        try:
            data = staging / "data"
            data.mkdir(mode=0o700)
            # Publish lock fixes the immutable code set; copy it before pinning a
            # SQLite snapshot. No live database, runtime or workspace is copied.
            copy_tree(source / "source.git", data / "source.git", policy)
            (data / "artifacts").mkdir(mode=0o700)
            for path in sorted((source / "artifacts").iterdir()):
                if HEX64.fullmatch(path.name):
                    copy_tree(path, data / "artifacts" / path.name, policy)
                else:
                    require(path.name.startswith(".publishing-"), "unknown artifact path")
            (data / "state").mkdir(mode=0o700)
            point = snapshot(source / "state/agent.sqlite3", data / "state/agent.sqlite3", policy)
            verify_state(data, point)
            record = {"schema_version": 1, "policy": policy, "recovery_point": point,
                      "completed_at_ms": now_ms(), "files": inventory(data)}
            encoded = canonical(record)
            identity = hashlib.sha256(encoded).hexdigest()
            (staging / "manifest.json").write_bytes(encoded)
            sync_tree(staging)
            reserve(staging, 0, policy)
            require(not (destination / identity).exists(), "backup already exists")
            os.rename(staging, destination / identity)
            sync_dir(destination)
            return {"backup_id": identity, "path": str(destination / identity), "recovery_point": point}
        finally:
            if staging.exists():
                shutil.rmtree(staging)


def verify_backup(path):
    root = private_path(path)
    require(HEX64.fullmatch(root.name), "backup directory must be its content identity")
    require({p.name for p in root.iterdir()} == {"manifest.json", "data"}, "unexpected backup contents")
    manifest_path = root / "manifest.json"
    require(manifest_path.is_file() and not manifest_path.is_symlink() and manifest_path.stat().st_nlink == 1
            and manifest_path.stat().st_size <= 16 * 1024 * 1024,
            "invalid backup manifest")
    encoded = manifest_path.read_bytes()
    require(hashlib.sha256(encoded).hexdigest() == root.name, "backup manifest digest mismatch")
    record = json.loads(encoded)
    require(record["schema_version"] == 1 and canonical(record) == encoded, "unsupported backup format")
    validate_policy(record["policy"])
    require(inventory(root / "data") == record["files"], "backup inventory mismatch")
    allowed = {"source.git", "artifacts", "state"}
    require({p.name for p in (root / "data").iterdir()} == allowed, "unexpected backup data")
    require({p.name for p in (root / "data/state").iterdir()} == {"agent.sqlite3"}, "unexpected state files")
    verify_state(root / "data", record["recovery_point"])
    return root, record


def restore(backup_path, target_path, epoch_floor, failure_time_ms):
    started = time.monotonic()
    source, record = verify_backup(backup_path)
    policy = record["policy"]
    point = record["recovery_point"]
    require(type(epoch_floor) is int and point["epoch_floor"] <= epoch_floor < 2**63 - 1,
            "epoch floor must cover all previously issued epochs")
    require(type(failure_time_ms) is int and failure_time_ms >= point["snapshot_started_at_ms"], "invalid failure time")
    rpo = failure_time_ms - point["snapshot_started_at_ms"]
    require(rpo <= policy["rpo_ms"], "backup exceeds declared recovery point objective")
    target = Path(target_path).expanduser().absolute()
    parent = private_path(target.parent)
    require(not target.is_symlink(), "restore target must not be a symlink")
    target = parent / target.name
    separate(source, target)
    separate(Path(__file__).resolve().parent.parent, target)
    require(not target.exists(), "restore requires an absent target; existing data is never overwritten")
    staging = Path(tempfile.mkdtemp(prefix=".restore-", dir=parent))
    try:
        for name in ("source.git", "artifacts", "state"):
            copy_tree(source / "data" / name, staging / name, policy)
        require(inventory(staging) == record["files"], "restore copy inventory mismatch")
        verify_state(staging, point)
        for artifact in (staging / "artifacts").iterdir():
            for name in ("seed", "manifest.json"):
                (artifact / name).chmod(0o444)
        recovery = {"schema_version": 1, "backup_id": source.name, "pending": True,
                    "source_event_seq": point["event_seq"], "epoch_floor": epoch_floor,
                    "snapshot_started_at_ms": point["snapshot_started_at_ms"],
                    "failure_time_ms": failure_time_ms, "prepared_at_ms": now_ms(), "policy": policy}
        # Allow for SQLite's rollback journal while adding the restore fence.
        reserve(staging, (staging / "state/agent.sqlite3").stat().st_size, policy)
        with closing(sqlite3.connect(staging / "state/agent.sqlite3")) as connection:
            with connection:
                connection.execute("PRAGMA synchronous=FULL")
                connection.execute("INSERT OR REPLACE INTO control VALUES('restore',?)", (canonical(recovery).decode(),))
                route = {**point["routing"], "admission": "closed"}
                connection.execute("UPDATE routing SET data=? WHERE id=1", (canonical(route).decode(),))
                connection.execute("INSERT INTO events(kind,data) VALUES('restore_prepared',?)", (canonical(recovery).decode(),))
        sync_tree(staging)
        reserve(staging, 0, policy)
        # Target parent is operator-owned. Check again before atomic publication.
        require(not target.exists() and not target.is_symlink(), "restore target was created concurrently")
        os.rename(staging, target)
        sync_dir(parent)
        return {"backup_id": source.name, "data_root": str(target), "verification_required": True,
                "copy_and_verify_ms": int((time.monotonic() - started) * 1000), "rpo_ms": rpo,
                "rto_budget_ms": policy["rto_ms"]}
    finally:
        if staging.exists():
            shutil.rmtree(staging)
