#!/usr/bin/env python3
"""Provision and boot with the documented defaults, then verify path overrides."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

CHECKOUT = Path(__file__).resolve().parents[2]


def main():
    with tempfile.TemporaryDirectory(prefix="ae-defaults-") as directory:
        home = Path(directory)
        env = {name: value for name, value in os.environ.items() if not name.startswith("AE_")}
        env.update(HOME=str(home), AE_LLM_MODEL="fixture")
        # Seed the build dependency cache before switching to the temporary home.
        package = Path(os.environ.get("AE_JSX_PACKAGE",
            str(Path.home() / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar")))
        cached = home / ".cache/rebar3/hex/hexpm/packages/jsx-3.1.0.tar"
        cached.parent.mkdir(parents=True)
        shutil.copyfile(package, cached)
        root = home / ".local/share/adam-eve"
        publication = subprocess.run([str(CHECKOUT / "scripts/publish_seed")], cwd=CHECKOUT,
            env=env, text=True, capture_output=True, timeout=120)
        assert publication.returncode == 0, publication.stderr
        assert (root / "bootstrap.json").is_file()
        for settings in (env, {**env, "HOME": str(home / "other-home"), "AE_DATA_ROOT": str(root)}):
            result = subprocess.run([str(CHECKOUT / "scripts/ae")], cwd=CHECKOUT, env=settings,
                input='{"op":"status"}\n', text=True, capture_output=True, check=True, timeout=30)
            assert json.loads(result.stdout)["runtime_health"] == "ok", result
        # Both override forms must select the existing identity and refuse reprovisioning.
        for arguments, settings in (
            ([], {**env, "HOME": str(home / "other-home"), "AE_DATA_ROOT": str(root)}),
            (["--data-root", str(root)], {**env, "AE_DATA_ROOT": str(home / "unused")}),
        ):
            result = subprocess.run([str(CHECKOUT / "scripts/publish_seed"), *arguments],
                cwd=CHECKOUT, env=settings, text=True, capture_output=True, timeout=30)
            assert result.returncode != 0 and "identity already provisioned" in result.stderr, result
        assert not (home / "unused").exists()
    print("Default configuration and path overrides passed")


if __name__ == "__main__":
    main()
