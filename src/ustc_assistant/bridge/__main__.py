from __future__ import annotations

import argparse
import json
import sys

from ustc_assistant.bridge.server import BridgeServer


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="python -m ustc_assistant.bridge")
    parser.add_argument("--parent-pid", type=int)
    args = parser.parse_args(argv)
    server = BridgeServer(parent_pid=args.parent_pid)
    sys.stdout.write(
        json.dumps(server.handshake(), separators=(",", ":")) + "\n"
    )
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
