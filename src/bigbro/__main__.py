"""The `bigbro` command.

`serve` runs the daemon. Everything else is a thin client that sends one command
over the control socket and prints the reply, so `bigbro pair approve` works from any
shell while the daemon runs in another — or under launchd with no terminal at all.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import sys

from .config import DEFAULT_PORT
from .control import ControlClientError, send_command


def _configure_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)-16s %(message)s",
        datefmt="%H:%M:%S",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bigbro",
        description="Turn your Mac into a local AI inference server for nearby iOS devices.",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="debug logging")
    sub = parser.add_subparsers(dest="command", required=True)

    serve = sub.add_parser("serve", help="run the inference daemon")
    serve.add_argument("--port", type=int, default=None, help=f"TCP port (default {DEFAULT_PORT})")
    serve.add_argument(
        "--no-keep-awake",
        action="store_true",
        help="let the Mac sleep normally instead of holding it awake while serving",
    )
    serve.add_argument(
        "--no-ui",
        action="store_true",
        help="plain logs instead of the dashboard, even on a terminal",
    )

    sub.add_parser("ui", help="attach the dashboard to a running daemon")
    sub.add_parser("status", help="show what the running daemon is doing")

    pair = sub.add_parser("pair", help="manage paired devices").add_subparsers(dest="action", required=True)
    pair.add_parser("list", help="list paired devices and pending requests")
    for action, help_text in (
        ("approve", "approve a pending pairing request"),
        ("deny", "deny a pending pairing request"),
        ("remove", "forget a paired device"),
        ("disconnect", "close a device's connection without forgetting it"),
    ):
        node = pair.add_parser(action, help=help_text)
        node.add_argument("device", help="device id, or any unambiguous prefix of one")
    pair.add_parser("remove-all", help="forget every paired device")

    models = sub.add_parser("models", help="manage models").add_subparsers(dest="action", required=True)
    models.add_parser("list", help="list catalog models and their state")
    models.add_parser("check", help="verify every catalog repo id resolves on Hugging Face")
    for action, help_text in (
        ("download", "fetch a model's weights to disk"),
        ("run", "load a model into memory"),
        ("stop", "unload a model from memory, keeping the download"),
        ("remove", "delete a model's weights from disk"),
    ):
        node = models.add_parser(action, help=help_text)
        node.add_argument("model", help="catalog id, or 'tts' / 'stt'")

    return parser


# MARK: - serve

def cmd_serve(args: argparse.Namespace) -> int:
    from .daemon import Daemon, require_macos

    require_macos()
    # `--no-keep-awake` is a flag, so its absence cannot be distinguished from an
    # explicit "yes" — pass None and let the config file decide unless it was given.
    keep_awake = False if args.no_keep_awake else None
    daemon = Daemon(port=args.port, keep_awake=keep_awake)

    use_ui = not args.no_ui and sys.stdout.isatty() and sys.stdin.isatty()
    try:
        asyncio.run(_serve_with_ui(daemon) if use_ui else daemon.run())
    except KeyboardInterrupt:
        pass
    return 0


async def _serve_with_ui(daemon) -> None:
    """Runs the daemon and the dashboard together, on one event loop.

    The dashboard still talks over the control socket rather than reaching into the
    daemon object, so this is the same code path `bigbro ui` takes — one
    implementation, and the attached case cannot quietly diverge from this one.
    """
    from .events import LogEventHandler
    from .tui import BigBroApp

    # Stdout belongs to the TUI now. Log records reach the UI through the event bus
    # instead; left on stdout they would tear the rendering apart.
    root = logging.getLogger()
    stream_handlers = [h for h in root.handlers if isinstance(h, logging.StreamHandler)]
    for handler in stream_handlers:
        root.removeHandler(handler)
    root.addHandler(LogEventHandler(daemon.events))

    server = asyncio.create_task(daemon.run())
    try:
        await BigBroApp(owns_daemon=True).run_async()
    finally:
        daemon.stop()
        with contextlib.suppress(asyncio.CancelledError, Exception):
            await asyncio.wait_for(server, timeout=10)


def cmd_ui(_args: argparse.Namespace) -> int:
    """Attaches the dashboard to a daemon started elsewhere. Quitting leaves it running."""
    from .control import ControlClientError
    from .tui import BigBroApp

    async def main() -> None:
        # Fail here with the actionable message rather than opening an empty
        # dashboard that silently retries against nothing.
        try:
            await send_command({"command": "status"})
        except ControlClientError as exc:
            raise SystemExit(f"error: {exc}")
        await BigBroApp(owns_daemon=False).run_async()

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
    return 0


# MARK: - control-socket commands

def _call(command: dict) -> dict:
    try:
        return asyncio.run(send_command(command))
    except ControlClientError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


def cmd_status(_args: argparse.Namespace) -> int:
    reply = _call({"command": "status"})
    if not reply.get("ok"):
        print(f"error: {reply.get('error')}", file=sys.stderr)
        return 1

    print(f"bigbro on {reply['name']}, port {reply['port']}")
    print(f"  keep-awake:  {'held' if reply['keepAwake'] else 'off'}")
    print(f"  paired:      {reply['paired']} device(s), {len(reply['connected'])} connected")
    if reply.get("pending"):
        print(f"  pending:     {len(reply['pending'])} awaiting approval — see: bigbro pair list")
    print(f"  running:     {', '.join(reply['running']) or 'nothing'}")
    print(f"  downloaded:  {', '.join(reply['downloaded']) or 'nothing'}")
    for kind, state in reply.get("speech", {}).items():
        print(f"  {kind + ':':12s} {state}")
    return 0


def cmd_pair(args: argparse.Namespace) -> int:
    if args.action == "list":
        reply = _call({"command": "pair.list"})
        if not reply.get("ok"):
            print(f"error: {reply.get('error')}", file=sys.stderr)
            return 1

        pending = reply.get("pending", [])
        if pending:
            print("Pending approval:")
            for request in pending:
                print(
                    f"  {request['deviceId'][:8]}  {request['deviceName']} • {request['appName']}"
                    f"  (waiting {request['waitingSeconds']}s)"
                )
                if request.get("requiredModels"):
                    print(f"      requires: {', '.join(request['requiredModels'])}")
            print("\n  approve with: bigbro pair approve <id>\n")

        devices = reply.get("devices", [])
        if not devices:
            print("No paired devices.")
            return 0

        print("Paired devices:")
        for device in devices:
            mark = "●" if device["connected"] else "○"
            app = f" • {device['appName']}" if device["appName"] else ""
            print(f"  {mark} {device['deviceId'][:8]}  {device['name']}{app}")
            if device.get("requiredModels"):
                print(f"      requires: {', '.join(device['requiredModels'])}")
        return 0

    if args.action == "remove-all":
        reply = _call({"command": "pair.remove-all"})
        if not reply.get("ok"):
            print(f"error: {reply.get('error')}", file=sys.stderr)
            return 1
        print(f"Forgot {reply['removed']} device(s).")
        return 0

    command = {"approve": "pair.approve", "deny": "pair.deny",
               "remove": "pair.remove", "disconnect": "pair.disconnect"}[args.action]
    reply = _call({"command": command, "deviceId": args.device})
    if not reply.get("ok"):
        print(f"error: {reply.get('error')}", file=sys.stderr)
        return 1

    if args.action in ("approve", "deny"):
        verb = "Approved" if args.action == "approve" else "Denied"
        print(f"{verb} {reply['deviceName']} ({reply['deviceId'][:8]}).")
    elif args.action == "remove":
        print(f"Forgot {reply['name']} ({reply['deviceId'][:8]}).")
    else:
        print(f"Disconnected {reply['deviceId'][:8]}.")
    return 0


def cmd_models(args: argparse.Namespace) -> int:
    if args.action == "check":
        return _check_catalog()

    if args.action == "list":
        reply = _call({"command": "models.list"})
        if not reply.get("ok"):
            print(f"error: {reply.get('error')}", file=sys.stderr)
            return 1

        print(f"{'ID':22s} {'SIZE':>7s}  {'CAPS':10s} {'STATE'}")
        for model in reply["models"]:
            caps = "".join([
                "T" if model["tools"] else "-",
                "I" if model["images"] else "-",
                "R" if model["reasoning"] != "none" else "-",
            ])
            print(f"{model['id']:22s} {model['sizeGB']:>6.1f}G  {caps:10s} {model['state']}")
        print()
        for entry in reply.get("speech", []):
            print(f"{entry['id']:22s} {'':>7s}  {'':10s} {entry['state']}  ({entry['name']})")
        print("\ncaps: T=tools I=images R=reasoning")
        return 0

    command = f"models.{args.action}"
    reply = _call({"command": command, "model": args.model})
    if not reply.get("ok"):
        print(f"error: {reply.get('error')}", file=sys.stderr)
        return 1

    if args.action == "download":
        print(f"Started downloading {reply['model']} — watch progress with: bigbro models list")
    else:
        print(f"{args.action.capitalize()}ped {reply['model']}."
              if args.action == "stop" else f"{args.action.capitalize()} {reply['model']}: done.")
    return 0


def _check_catalog() -> int:
    """Verifies every catalog repo id resolves on the Hub.

    Runs without a daemon and without downloading anything. This is the check that
    catches a repo that was renamed or never existed — the one class of catalog error
    that otherwise only surfaces as a failed download mid-request.
    """
    from huggingface_hub import HfApi
    from huggingface_hub.utils import HfHubHTTPError

    from .inference.catalog import ALL_MODELS

    api = HfApi()
    failures = 0
    for model in ALL_MODELS:
        try:
            api.model_info(model.repo)
            print(f"  ok    {model.id:22s} {model.repo}")
        except (HfHubHTTPError, OSError) as exc:
            failures += 1
            reason = getattr(getattr(exc, "response", None), "status_code", exc)
            print(f"  FAIL  {model.id:22s} {model.repo}  -> {reason}")

    print()
    if failures:
        print(f"{failures} of {len(ALL_MODELS)} catalog entries did not resolve.")
        return 1
    print(f"All {len(ALL_MODELS)} catalog entries resolve.")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _configure_logging(args.verbose)

    if args.command == "serve":
        return cmd_serve(args)
    if args.command == "ui":
        return cmd_ui(args)
    if args.command == "status":
        return cmd_status(args)
    if args.command == "pair":
        return cmd_pair(args)
    if args.command == "models":
        return cmd_models(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
