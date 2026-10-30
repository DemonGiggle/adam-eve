"""Pinned inputs for the standalone manual-publication tools.

The Erlang controller has its own host builder and does not invoke this module.
"""
from contextlib import contextmanager
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tarfile
import tempfile

PACKAGE_SHA256 = "0c5cc8fdc11b53cc25cf65ac6705ad39e54ecc56d1c22e4adb8f5a53fb9427f3"
RECIPE = Path(__file__).resolve().parent.parent / "apps/ae_core/priv/build_seed.escript"


@contextmanager
def pinned_dependency(package=None):
    package = Path(package) if package is not None else Path(os.environ.get("AE_JSX_PACKAGE",
        str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar")))
    if not package.exists():
        raise RuntimeError("locked jsx package is unavailable; run scripts/build or set AE_JSX_PACKAGE")
    if package.stat().st_size > 4 * 1024 * 1024:
        raise RuntimeError("dependency package exceeds the pinned package limit")
    data = package.read_bytes()
    if hashlib.sha256(data).hexdigest() != PACKAGE_SHA256:
        raise RuntimeError("locked jsx package checksum mismatch")
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as outer:
        if sorted(outer.getnames()) != ["CHECKSUM", "VERSION", "contents.tar.gz", "metadata.config"]:
            raise RuntimeError("unexpected locked package envelope")
        contents = outer.extractfile("contents.tar.gz").read()
    with tempfile.TemporaryDirectory(prefix="ae-jsx-") as directory:
        root = Path(directory)
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as archive:
            total = 0
            for member in archive:
                path = PurePosixPath(member.name)
                if not member.isfile() or path.is_absolute() or any(p in ("", ".", "..") for p in path.parts):
                    raise RuntimeError("unsafe dependency package member")
                total += member.size
                if total > 16 * 1024 * 1024:
                    raise RuntimeError("dependency sources exceed extraction limit")
                target = root.joinpath(*path.parts)
                target.parent.mkdir(parents=True, exist_ok=True)
                with target.open("xb") as output:
                    output.write(archive.extractfile(member).read())
        yield root


def recipe_arguments(source, dependency, revision, tree, parent, output):
    return [str(RECIPE), str(Path(source).resolve()), str(Path(dependency).resolve()), revision, tree,
            parent or "-", PACKAGE_SHA256, hashlib.sha256(RECIPE.read_bytes()).hexdigest(),
            "-" if str(output) == "-" else str(Path(output).resolve())]


def build_manual(source, revision, tree, parent, output, *, trusted_manual=False):
    """Compile only explicitly trusted manual source, without a sandbox fallback."""
    if trusted_manual is not True:
        raise RuntimeError("standalone manual publication requires explicit manual trust")
    executable = shutil.which("escript")
    if executable is None:
        raise RuntimeError("Erlang escript is required")
    environment = {"PATH": str(Path(executable).parent) + ":/usr/bin:/bin", "LANG": "C.UTF-8", "TZ": "UTC"}
    with pinned_dependency() as dependency:
        subprocess.run([executable, *recipe_arguments(source, dependency, revision, tree, parent, output)],
                       check=True, env=environment)
    return {"recipe": "ae_seed_v1", "recipe_sha256": hashlib.sha256(RECIPE.read_bytes()).hexdigest(),
            "dependency": {"name": "jsx", "version": "3.1.0", "package_sha256": PACKAGE_SHA256}}
