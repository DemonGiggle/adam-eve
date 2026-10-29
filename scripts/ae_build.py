"""Manual publisher compatibility entry point for controller-owned build inputs."""
import importlib.util
from pathlib import Path

_path = Path(__file__).resolve().parent.parent / "apps/ae_core/priv/ae_build_inputs.py"
_spec = importlib.util.spec_from_file_location("ae_build_inputs", _path)
_inputs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_inputs)

PACKAGE_SHA256 = _inputs.PACKAGE_SHA256
RECIPE = _inputs.RECIPE
pinned_dependency = _inputs.pinned_dependency
recipe_arguments = _inputs.recipe_arguments
build_manual = _inputs.build_manual
