#!/usr/bin/env python3
"""Exercise the Erlang host builder and independent evaluator end to end."""
import os
from pathlib import Path
import subprocess
import tempfile

from phase0 import CHECKOUT


def main():
    with tempfile.TemporaryDirectory(prefix="ae-host-build-") as directory:
        root = Path(directory) / "identity"
        subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True)
        package = os.environ.get("AE_JSX_PACKAGE", str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar"))
        subprocess.run(["escript", str(CHECKOUT / "test/integration/host_build.escript"), str(root), package],
            cwd=CHECKOUT, check=True)


if __name__ == "__main__":
    main()
