#!/usr/bin/env python3
"""Publish the trusted boot seed from a frozen source copy, outside the checkout."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import fcntl
import sys
from contextlib import contextmanager


def run(*args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, stderr=subprocess.STDOUT).decode().strip()


def sync_tree(root):
    for base, _, files in os.walk(root, topdown=False):
        for name in files:
            with open(Path(base) / name, "rb") as file:
                os.fsync(file.fileno())
        sync_dir(Path(base))


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def write_sync(path, data):
    with open(path, "xb") as file:
        file.write(data)
        file.flush()
        os.fchmod(file.fileno(), 0o444)
        os.fsync(file.fileno())


def data_root(path):
    checkout = Path(__file__).resolve().parent.parent
    root = path.expanduser().absolute()
    if root.is_symlink():
        raise ValueError("data root must not be a symlink")
    root = root.resolve()
    if root == checkout or checkout in root.parents:
        raise ValueError("data root must be outside the development checkout")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    if root.is_symlink() or root.stat().st_mode & 0o077:
        raise ValueError("data root must be a private, non-symlink directory (mode 0700)")
    for name in ("artifacts", "workspaces", "state"):
        (root / name).mkdir(exist_ok=True, mode=0o700)
    repo = root / "source.git"
    if not repo.exists():
        run("git", "init", "--bare", str(repo))
    return root


@contextmanager
def publication_lock(root):
    with open(root / "publication.lock", "a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def publish(root, workspace, parent=None, objective="Trusted boot seed"):
    repo = root / "source.git"
    run("git", "-c", "user.name=adam-eve bootstrap", "-c",
        "user.email=bootstrap@localhost", "commit", "-m", objective, cwd=workspace)
    revision = run("git", "rev-parse", "HEAD", cwd=workspace)
    tree = run("git", "rev-parse", "HEAD^{tree}", cwd=workspace)
    print("Building frozen agent source...", file=sys.stderr, flush=True)
    subprocess.run(["rebar3", "escriptize"], cwd=workspace / "apps/ae_seed", check=True, stdout=sys.stderr)
    run("git", "diff", "--exit-code", "HEAD", cwd=workspace)
    if run("git", "ls-files", "--others", "--exclude-standard", cwd=workspace):
        raise RuntimeError("build introduced unlocked source inputs; run scripts/build first")
    executable = (workspace / "apps/ae_seed/_build/default/bin/seed").read_bytes()
    digest = hashlib.sha256(executable).hexdigest()
    manifest = {
        "digest": digest,
        "source_revision": revision,
        "source_tree": tree,
        "otp_release": run("erl", "+S", "2:2", "-noshell", "-eval",
                           'io:format("~s", [erlang:system_info(otp_release)]), halt().'),
        "erts_version": run("erl", "+S", "2:2", "-noshell", "-eval",
                            'io:format("~s", [erlang:system_info(version)]), halt().'),
        "capabilities": ["memory_read", "llm"],
        "state_schema_versions": [1],
        "build_recipe": "apps/ae_seed: rebar3 escriptize",
        "rebar_version": run("rebar3", "version"),
        "parent": parent,
        "objective": objective,
        "authoring": "trusted_manual",
    }
    encoded = json.dumps(manifest, sort_keys=True, indent=2).encode() + b"\n"
    # Protected ref and complete executable are published before bootstrap metadata.
    run("git", "--git-dir", str(repo), "fetch", str(workspace),
        f"HEAD:refs/generations/{digest}")
    sync_tree(repo)
    temporary = Path(tempfile.mkdtemp(prefix=".publishing-", dir=root / "artifacts"))
    write_sync(temporary / "seed", executable)
    write_sync(temporary / "manifest.json", encoded)
    sync_dir(temporary)
    os.rename(temporary, root / "artifacts" / digest)
    sync_dir(root / "artifacts")
    if parent is None:
        staged = root / (".bootstrap-" + digest)
        write_sync(staged, encoded)
        os.link(staged, root / "bootstrap.json")
        staged.unlink()
    sync_dir(root)
    return manifest
