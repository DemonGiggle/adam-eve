#!/usr/bin/env python3
"""Exercise the operator CLI without granting generated code a host fallback."""
import tempfile
import subprocess
import threading
from http.server import ThreadingHTTPServer
from pathlib import Path

from phase0 import CHECKOUT, Controller, Provider, turn


def main():
    provider = ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    try:
        with tempfile.TemporaryDirectory(prefix="ae-evolution-control-") as directory:
            root = Path(directory)
            subprocess.run([str(CHECKOUT / "scripts/publish_seed"), "--data-root", str(root)], check=True)
            # A requested enable cannot bypass missing limits or isolation.
            for requested in ("false", "true"):
                controller = Controller(root, provider.server_port, {
                    "AE_EVOLUTION_ENABLED": requested, "AE_RUNTIME_ISOLATION": "development",
                    "AE_EVOLUTION_LIMITS_JSON": "{}", "AE_BUILD_CONFIG_JSON": "{}",
                    "AE_EVAL_CONFIG_JSON": "{}", "AE_EVOLUTION_LLM_TIMEOUT_MS": "invalid"})
                try:
                    status = controller.command("evolution")
                    assert status["enabled"] is False, status
                    assert controller.command("evolve", origin_ref="disabled", objective="improve") == {
                        "error": "evolution_disabled"}
                    assert controller.command("evolution_enable", enabled=True) == {
                        "error": "evolution_not_configured"}
                    for invalid in ("", "not-an-id", 42, {}, ["a" * 64]):
                        assert controller.command("evolution", job_id=invalid) == {"error": "invalid_job_id"}
                        assert controller.command("evolution_cancel", job_id=invalid) == {"error": "invalid_job_id"}
                    assert controller.command("evolution", job_id="a" * 64) == {"error": "unknown_job"}
                    assert controller.command("evolution_enable", enabled=False) == {"ok": True}
                    assert controller.command("evolution_enable", enabled="true") == {"error": "unknown_command"}
                    assert turn(controller, "service-" + requested, "hello")["text"] == "reply:hello"
                    assert controller.command("status")["runtime_health"] == "ok"
                    controls = [event for event in controller.command("history")["events"]
                                if event["kind"] == "evolution_mode_changed"]
                    assert len(controls) == (1 if requested == "false" else 2), controls
                finally:
                    controller.close()
    finally:
        provider.shutdown()
        provider.server_close()
    print("Evolution CLI passed: fail-closed configuration, malformed requests, durable disable and ordinary service.")


if __name__ == "__main__":
    main()
