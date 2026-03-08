#!/usr/bin/env python3
"""psono-ssh-agent — manages an ssh-agent with keys loaded from Psono.

Architecture:
  - Starts a real ssh-agent bound to the configured socket path
  - Loads all Psono SSH keys via `psonoci ssh add --key-lifetime`
  - Keys auto-expire in the agent; refresh loop re-adds them before expiry
"""

import json
import logging
import os
import signal
import subprocess
import sys
import time
from pathlib import Path


def load_all_keys(accounts: list, socket_path: str, key_lifetime: int):
    count = 0
    for account in accounts:
        name       = account["name"]
        psono_cfg  = str(Path(account["psono_config"]).expanduser())
        try:
            result = subprocess.run(
                ["psonoci", "-c", psono_cfg, "api-key", "secrets"],
                capture_output=True, text=True, check=True,
            )
            secrets = json.loads(result.stdout)
        except Exception as e:
            logging.error("Failed to fetch secrets for '%s': %s", name, e)
            continue

        for secret_id, data in secrets.items():
            title = data.get("title", secret_id[:8])
            try:
                subprocess.run(
                    ["psonoci", "-c", psono_cfg, "ssh", "add", secret_id,
                     "--ssh-auth-sock-path", socket_path,
                     "--key-lifetime", str(key_lifetime)],
                    capture_output=True, text=True, check=True,
                )
                logging.info("Loaded [%s] %s", name, title)
                count += 1
            except subprocess.CalledProcessError as e:
                logging.error("Failed to load [%s] %s: %s", name, title, e.stderr.strip())

    logging.info("Total: %d key(s) loaded", count)


def main():
    cfg_path = Path(os.environ.get(
        "PSONO_AGENT_CONFIG", "~/.config/psono-agent/config.json"
    )).expanduser()

    with open(cfg_path) as f:
        cfg = json.load(f)

    socket_path = str(Path(cfg["socket_path"]).expanduser())
    cache_ttl   = cfg.get("cache_ttl", 300)
    log_level   = cfg.get("log_level", "INFO").upper()
    accounts    = cfg["accounts"]

    logging.basicConfig(
        level=getattr(logging, log_level),
        format="%(asctime)s [%(levelname)s] %(message)s",
    )

    # Remove stale socket
    sock = Path(socket_path)
    if sock.exists():
        sock.unlink()

    # Start ssh-agent bound to our socket; parse its PID from stdout
    result = subprocess.run(
        ["ssh-agent", "-a", socket_path],
        capture_output=True, text=True,
    )
    agent_pid = None
    for line in result.stdout.splitlines():
        if "SSH_AGENT_PID=" in line:
            agent_pid = int(line.split("SSH_AGENT_PID=")[1].split(";")[0])
            break

    if not agent_pid:
        logging.error("Failed to start ssh-agent or parse its PID:\n%s", result.stdout)
        sys.exit(1)

    logging.info("ssh-agent started (pid %d) on %s", agent_pid, socket_path)

    def shutdown(sig, frame):
        logging.info("Shutting down …")
        try:
            os.kill(agent_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        sock.unlink(missing_ok=True)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Refresh slightly before keys expire to avoid a gap
    refresh_interval = max(cache_ttl - 30, 30)

    while True:
        logging.info("Loading keys from Psono …")
        load_all_keys(accounts, socket_path, cache_ttl)
        time.sleep(refresh_interval)


if __name__ == "__main__":
    main()
