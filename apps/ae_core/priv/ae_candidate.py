"""Trusted candidate preparation/build; never execute candidate code on the host.

The caller supplies a durable, already-accepted proposal and execution lease.
Built contents are retained but are not independently evaluated or deployable.
"""
import argparse
import base64
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import selectors
import shutil
import subprocess
import sys
import tempfile
import time

import ae_build_inputs as inputs
import ae_sandbox as sandbox

HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
ENV = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "LC_ALL": "C.UTF-8", "TZ": "UTC",
       "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
       "GIT_NO_REPLACE_OBJECTS": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
       "GIT_ALLOW_PROTOCOL": ""}


class BuildError(RuntimeError):
    def __init__(self, reason, diagnostics=""):
        super().__init__(reason)
        self.reason, self.diagnostics = reason, diagnostics


def require(condition, reason):
    if not condition:
        raise BuildError(reason)


def canonical(record):
    return json.dumps(record, sort_keys=True, separators=(",", ":")).encode() + b"\n"


def sync_dir(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_tree(root):
    for base, _, files in os.walk(root, topdown=False):
        for name in files:
            path = Path(base) / name
            require(path.is_file() and not path.is_symlink(), "invalid_repository_file")
            with path.open("rb") as stream:
                os.fsync(stream.fileno())
        sync_dir(base)


@contextmanager
def publication_lock(root):
    with (root / "publication.lock").open("a+b") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def command(arguments, *, environment=None, data=None, cap=1048576, timeout=10):
    """Fixed tools only. Bound stdout before allocating it; suppress private errors."""
    with tempfile.TemporaryFile() as input_file:
        if data is not None:
            input_file.write(data)
            input_file.seek(0)
        with subprocess.Popen(arguments, stdin=input_file, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              env=environment or ENV, cwd="/", close_fds=True) as child:
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    result = bytearray()
                    deadline = time.monotonic() + timeout
                    while selector.get_map():
                        require(time.monotonic() < deadline, "source_operation_timeout")
                        for key, _ in selector.select(0.05):
                            chunk = os.read(key.fd, 65536)
                            if not chunk:
                                selector.unregister(child.stdout)
                            else:
                                require(len(result) + len(chunk) <= cap, "source_output_limit")
                                result.extend(chunk)
                    require(child.wait(timeout=max(0.1, deadline - time.monotonic())) == 0, "source_operation_failed")
                    return bytes(result)
            finally:
                if child.poll() is None:
                    child.kill()
                child.wait()


def git(root, *arguments, index=None, data=None, cap=1048576, extra_env=None):
    environment = {**ENV, **(extra_env or {})}
    if index is not None:
        environment["GIT_INDEX_FILE"] = str(index)
    return command(["/usr/bin/git", "--git-dir", str(root / "source.git"),
        "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.attributesFile=/dev/null",
        "-c", "gc.auto=0", "-c", "maintenance.auto=false", *arguments],
        environment=environment, data=data, cap=cap)


def validate_config(config):
    require(set(config) == {"cgroup_root", "jsx_package", "source_bytes", "source_files", "artifact_bytes", "sandbox_limits"},
            "build_configuration_required")
    for name in ("source_bytes", "source_files", "artifact_bytes"):
        require(type(config[name]) is int and 0 < config[name] < 2**63, "invalid_build_limit")
    for name in ("cgroup_root", "jsx_package"):
        require(isinstance(config[name], str) and Path(config[name]).is_absolute(), "invalid_build_path")
    sandbox.validate_limits(config["sandbox_limits"])
    return config


def reserve(root, count, job):
    require(shutil.disk_usage(root).free >= count + job["limits"]["disk_reserve_bytes"], "disk_reserve_exhausted")


def valid_path(path):
    return (isinstance(path, str) and 0 < len(path.encode()) <= 240
        and re.fullmatch(r"[A-Za-z0-9_./-]+", path) is not None
        and all(part not in ("", ".", "..") for part in path.split("/")))


def writable(path):
    return (valid_path(path) and path.startswith(("apps/ae_seed/src/", "apps/ae_seed/test/"))
            and Path(path).suffix in (".erl", ".hrl"))


def check_tree(root, revision, config):
    listing = git(root, "ls-tree", "-r", "-l", "-z", revision, cap=config["source_files"] * 512 + 1024)
    total, paths = 0, {}
    for record in listing.split(b"\0"):
        if not record:
            continue
        info, encoded = record.split(b"\t", 1)
        mode, kind, blob, size = info.split()
        path = encoded.decode("ascii")
        require(mode in (b"100644", b"100755") and kind == b"blob" and HEX40.fullmatch(blob.decode()), "unsafe_source_tree")
        public = writable(path) or path in ("apps/ae_seed/rebar.config", "apps/ae_seed/rebar.lock",
            "apps/ae_seed/src/ae_seed.app.src", "apps/ae_protocol/src/ae_protocol.erl",
            "apps/ae_protocol/src/ae_protocol.app.src", "docs/PROTOCOL.md", ".gitignore")
        protocol_test = path.startswith("apps/ae_protocol/test/") and Path(path).suffix in (".erl", ".hrl")
        require(valid_path(path) and (public or protocol_test), "protected_source_tree")
        total += int(size)
        paths[path] = (blob.decode(), int(size))
        require(len(paths) <= config["source_files"] and total <= config["source_bytes"], "source_tree_limit")
    require(paths, "empty_source_tree")
    return paths


def export_tree(root, revision, destination, config):
    paths = check_tree(root, revision, config)
    # Read raw blobs: checkout filters and archive export-subst/export-ignore
    # attributes must never change the bytes named by the retained tree.
    for name, (blob, size) in paths.items():
        if name.startswith("apps/ae_protocol/test/"):
            continue  # Controller-owned contract cases are not compiler inputs.
        data = git(root, "cat-file", "blob", blob, cap=size)
        require(len(data) == size, "incomplete_source_export")
        target = destination.joinpath(*PurePosixPath(name).parts)
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with target.open("xb") as stream:
            stream.write(data)


def prepare(root, job, proposal, workspace, config):
    """Use a private index; no checkout hooks, filters, worktrees or source code run."""
    base = job["baseline"]["artifact"]
    require(HEX64.fullmatch(job["id"]) and HEX64.fullmatch(base["digest"])
        and HEX40.fullmatch(base["source_revision"]) and HEX40.fullmatch(base["source_tree"]), "invalid_source_identity")
    require(job["status"] == "building" and type(proposal["attempt"]) is int
        and 0 < proposal["attempt"] == job["attempts"], "invalid_build_attempt")
    require(proposal["base_artifact"] == base["digest"] and proposal["base_source_revision"] == base["source_revision"]
        and proposal["epoch"] == job["baseline"]["epoch"], "stale_build_baseline")
    patch = proposal["patch"].encode()
    require(0 < len(patch) <= job["limits"]["max_patch_bytes"]
        and hashlib.sha256(patch).hexdigest() == proposal["patch_hash"], "invalid_patch_hash")
    allowed = proposal["paths"]
    require(allowed and len(allowed) <= 64 and len(set(allowed)) == len(allowed) and all(writable(p) for p in allowed), "protected_patch")
    repo = root / "source.git"
    for name in ("objects/info/alternates", "objects/info/http-alternates", "info/grafts", "shallow"):
        require(not (repo / name).exists(), "external_source_dependency")
    require(git(root, "rev-parse", "--verify", "refs/generations/" + base["digest"]).strip().decode() == base["source_revision"],
            "protected_source_mismatch")
    require(git(root, "rev-parse", "--verify", base["source_revision"] + "^{tree}").strip().decode() == base["source_tree"],
            "source_tree_mismatch")
    check_tree(root, base["source_revision"], config)
    index = workspace / "index"
    git(root, "read-tree", base["source_revision"], index=index)
    try:
        git(root, "apply", "--cached", "--unidiff-zero", "--whitespace=error-all", "-", index=index, data=patch)
    except BuildError as error:
        if error.reason == "source_operation_failed":
            raise BuildError("patch_did_not_apply", "Patch does not apply cleanly to its pinned source. Check paths, old lines and hunk counts.") from error
        raise
    changed = git(root, "diff", "--cached", "--name-only", "-z", base["source_revision"], index=index)
    require(sorted(p.decode() for p in changed.split(b"\0") if p) == sorted(allowed), "patch_scope_mismatch")
    tree = git(root, "write-tree", index=index).strip().decode()
    check_tree(root, tree, config)
    created = (job["deadline"] - job["limits"]["total_ms"]) // 1000
    identity = {"GIT_AUTHOR_NAME": "adam-eve builder", "GIT_AUTHOR_EMAIL": "builder@localhost",
        "GIT_COMMITTER_NAME": "adam-eve builder", "GIT_COMMITTER_EMAIL": "builder@localhost",
        "GIT_AUTHOR_DATE": f"{created} +0000", "GIT_COMMITTER_DATE": f"{created} +0000"}
    message = canonical({"job_id": job["id"], "attempt": proposal["attempt"], "patch_hash": proposal["patch_hash"],
                         "objective": job["objective"]})
    revision = git(root, "-c", "commit.gpgSign=false", "commit-tree", tree, "-p", base["source_revision"],
                   data=message, extra_env=identity).strip().decode()
    ref = f"refs/attempts/{job['id']}/{proposal['attempt']}"
    existing = git(root, "for-each-ref", "--format=%(objectname)", ref).strip().decode()
    require(not existing or existing == revision, "attempt_source_conflict")
    git(root, "update-ref", ref, revision, existing or "0" * 40)
    sync_tree(repo)
    source = workspace / "source"
    source.mkdir(mode=0o700)
    export_tree(root, revision, source, config)
    return source, revision, tree


def effective_limits(config, job, lease):
    limits = dict(config["sandbox_limits"])
    require(lease["kind"] == "build" and lease["status"] == "reserved" and lease["job_id"] == job["id"]
        and lease["attempt"] == job["attempts"]
        and type(lease["cpu_ms"]) is int and 0 < lease["cpu_ms"] <= job["limits"]["cpu_ms"]
        and type(lease["wall_ms"]) is int and 0 < lease["wall_ms"] <= job["limits"]["build_ms"], "execution_lease_required")
    require(type(lease["reserved_at_ms"]) is int and type(lease["expires_at_ms"]) is int
        and lease["expires_at_ms"] == lease["reserved_at_ms"] + lease["wall_ms"]
        and lease["expires_at_ms"] <= job["deadline"], "invalid_execution_expiry")
    remaining = min(job["deadline"], lease["expires_at_ms"]) - time.time_ns() // 1_000_000
    require(remaining > 0, "job_expired")
    limits["memory_bytes"] = min(limits["memory_bytes"], job["limits"]["memory_bytes"])
    limits["pids"] = min(limits["pids"], job["limits"]["processes"])
    limits["wall_ms"] = min(limits["wall_ms"], lease["wall_ms"], remaining)
    limits["cpu_seconds"] = min(limits["cpu_seconds"], (lease["cpu_ms"] + 999) // 1000)
    return limits


def diagnostics(output, maximum):
    text = output[:maximum].decode("utf-8", errors="replace")
    return "".join(c for c in text if c in "\n\t" or ord(c) >= 32).encode()[:maximum].decode("utf-8", errors="ignore")


def publish(root, executable, manifest, job):
    digest = manifest["digest"]
    target = root / "artifacts" / digest
    encoded = canonical(manifest)
    with publication_lock(root):
        reserve(root, len(executable) + len(encoded), job)
        # A protected ref and exact immutable contents exist before any registry update.
        ref = "refs/generations/" + digest
        previous = git(root, "for-each-ref", "--format=%(objectname)", ref).strip().decode()
        require(not previous or previous == manifest["source_revision"], "artifact_source_conflict")
        git(root, "update-ref", ref, manifest["source_revision"], previous or "0" * 40)
        sync_tree(root / "source.git")
        if target.exists():
            require((target / "manifest.json").read_bytes() == encoded and
                hashlib.sha256((target / "seed").read_bytes()).hexdigest() == digest, "artifact_conflict")
            # A prior publisher may have died immediately after rename, before
            # syncing the parent directory. Re-establish durability before any
            # caller records this already-present release as available.
            sync_dir(target)
            sync_dir(root / "artifacts")
            return
        staging = Path(tempfile.mkdtemp(prefix=".publishing-" + job["id"][:12] + "-", dir=root / "artifacts"))
        try:
            for name, data in (("seed", executable), ("manifest.json", encoded)):
                with (staging / name).open("xb") as stream:
                    stream.write(data)
                    stream.flush()
                    os.fchmod(stream.fileno(), 0o444)
                    os.fsync(stream.fileno())
            sync_dir(staging)
            os.rename(staging, target)
            sync_dir(root / "artifacts")
        finally:
            if staging.exists():
                shutil.rmtree(staging)


def build(root, job, proposal, lease, config, *, watch_parent=False):
    validate_config(config)
    require(isinstance(job.get("id"), str) and HEX64.fullmatch(job["id"]), "invalid_source_identity")
    root = Path(root).absolute()
    require(root.is_dir() and not root.is_symlink() and root.stat().st_uid == os.getuid()
        and root.stat().st_mode & 0o077 == 0, "private_data_root_required")
    for name in ("source.git", "artifacts", "workspaces"):
        require((root / name).is_dir() and not (root / name).is_symlink(), "invalid_data_root")
    limits = effective_limits(config, job, lease)
    reserve(root, config["source_bytes"] + config["artifact_bytes"] + 16 * 1024 * 1024, job)
    with tempfile.TemporaryDirectory(prefix="build-" + job["id"][:12] + "-", dir=root / "workspaces") as directory:
        workspace = Path(directory)
        with publication_lock(root):
            source, revision, tree = prepare(root, job, proposal, workspace, config)
        recipe_hash = hashlib.sha256(inputs.RECIPE.read_bytes()).hexdigest()
        with inputs.pinned_dependency(config["jsx_package"]) as dependency, \
                sandbox.sealed_release(inputs.RECIPE, recipe_hash, 1048576) as recipe:
            limits = effective_limits(config, job, lease)
            code, output, reason = sandbox.run(config["cgroup_root"], limits,
                ["/usr/bin/escript", "/recipe/build_seed.escript", "/source", "/dependency", revision, tree,
                 job["baseline"]["artifact"]["digest"], inputs.PACKAGE_SHA256,
                 recipe_hash, "-"],
                readonly=[(source, "/source"), (dependency, "/dependency")],
                data_files=[(recipe, "/recipe/build_seed.escript")],
                cpu_budget_ms=min(lease["cpu_ms"], limits["cpu_seconds"] * 1000), watch_parent=watch_parent)
        if code or reason:
            raise BuildError(reason or "compilation_failed", diagnostics(output, job["limits"]["max_diagnostic_bytes"]))
        try:
            prefix, encoded, empty = output.split(b"\n")
            require(prefix == b"AE_SEED_V1" and empty == b"", "invalid_build_output")
            executable = base64.b64decode(encoded, validate=True)
        except (ValueError, TypeError) as error:
            raise BuildError("invalid_build_output") from error
        require(0 < len(executable) <= config["artifact_bytes"], "artifact_size_limit")
        base = job["baseline"]["artifact"]
        manifest = {"digest": hashlib.sha256(executable).hexdigest(), "source_revision": revision, "source_tree": tree,
            "parent": base["digest"], "otp_release": base["otp_release"], "erts_version": base["erts_version"],
            "capabilities": base["capabilities"], "state_schema_versions": base["state_schema_versions"],
            "authoring": "llm", "objective": job["objective"], "producing_job": job["id"],
            "producing_attempt": proposal["attempt"], "patch_hash": proposal["patch_hash"],
            "build_recipe": "ae_seed_v1", "build_provenance": {"recipe": "ae_seed_v1",
                "recipe_sha256": recipe_hash,
                "dependency": {"name": "jsx", "version": "3.1.0", "package_sha256": inputs.PACKAGE_SHA256}},
            "evaluation": None}
        require(time.time_ns() // 1_000_000 < min(job["deadline"], lease["expires_at_ms"]), "job_expired")
        publish(root, executable, manifest, job)
        return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--request", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--watch-parent", action="store_true")
    args = parser.parse_args()
    try:
        require(args.request.stat().st_size <= 2 * 1024 * 1024 and args.config.stat().st_size <= 65536, "invalid_build_request")
        request = json.loads(args.request.read_bytes())
        config = json.loads(args.config.read_bytes())
        manifest = build(args.data_root, request["job"], request["proposal"], request["lease"], config,
                         watch_parent=args.watch_parent)
        print(json.dumps({"ok": True, "manifest": manifest}))
    except BuildError as error:
        print(json.dumps({"ok": False, "error": error.reason, "diagnostics": error.diagnostics}))
        sys.exit(1)
    except sandbox.Unavailable as error:
        print(json.dumps({"ok": False, "error": str(error), "diagnostics": ""}))
        sys.exit(1)
    except Exception:
        print(json.dumps({"ok": False, "error": "build_failed", "diagnostics": ""}))
        sys.exit(1)


if __name__ == "__main__":
    main()
