"""The `bigbro` command.

`serve` runs the daemon; BigBro.app and every other verb are clients of it.

Everything but `serve` is a thin client that sends one command
over the control socket and prints the reply, so `bigbro pair approve` works from any
shell while the daemon runs in another — or under launchd with no terminal at all.
"""

from __future__ import annotations

import argparse
import asyncio
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
    # Accepted and ignored. `serve` has only ever done one thing since the
    # dashboard moved into BigBro.app, but this flag is in people's launchd
    # plists and shell history, and BigBro.app itself passes it — failing on it
    # would break the app for the sake of tidiness.
    serve.add_argument("--no-ui", action="store_true", help=argparse.SUPPRESS)

    sub.add_parser("status", help="show what the running daemon is doing")
    sub.add_parser("shutdown", help="stop the running daemon")

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
    # The four verbs name the two axes a model moves along, and they are kept
    # distinct on purpose: download/delete are about disk, start/stop are about
    # memory. A 12 GB model on disk costs nothing until it is started.
    for action, help_text in (
        ("download", "fetch a model's weights to disk"),
        ("delete", "remove a model's weights from disk"),
        ("start", "load a downloaded model into memory"),
        ("stop", "unload a model from memory, keeping the download"),
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

    try:
        asyncio.run(_serve(daemon))
    except KeyboardInterrupt:
        pass
    return 0


async def _serve(daemon) -> None:
    """Runs the daemon with logs on stderr, mirrored onto the event bus.

    The bus handler matters even though nothing in *this* process renders it: a
    client attached over the control socket reads its log view from those events
    and can no more see this stderr than it could see a launchd daemon's. Without
    this, `--no-ui` publishes no `log` events at all — the exact gap
    `LogEventHandler` exists to close — and an attached UI shows an empty log for
    the case that needs it most.

    Unlike the dashboard path this *adds* the handler rather than replacing the
    stream one: nothing here owns stdout, so the logs someone ran `serve` to watch
    stay where they are.
    """
    from .events import LogEventHandler

    logging.getLogger().addHandler(LogEventHandler(daemon.events))
    await daemon.run()


# MARK: - control-socket commands

def _call(command: dict) -> dict:
    try:
        return asyncio.run(send_command(command))
    except ControlClientError as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc


def cmd_shutdown(_args: argparse.Namespace) -> int:
    """Stops a daemon started anywhere — a terminal since closed, or BigBro.app.

    Ctrl-C only works if you still have the terminal that started it, and a
    daemon nobody can see is still holding the Mac awake.
    """
    reply = _call({"command": "daemon.shutdown"})
    if not reply.get("ok"):
        print(f"error: {reply.get('error', 'the daemon refused to stop')}", file=sys.stderr)
        return 1
    print("daemon stopping")
    return 0


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
    mem = reply.get("memory") or {}
    if mem.get("headline"):
        from .macos.memory import human
        mlx = mem.get("mlx") or {}
        label = "weights" if mem.get("weights") else "process"
        line = f"  memory:      {human(mem['headline'])} ({label})"
        if mem.get("total"):
            line += f" of {human(mem['total'])} ({mem['headline'] / mem['total'] * 100:.0f}%)"
        if mem.get("pressure") and mem["pressure"] != "normal":
            line += f" — pressure {mem['pressure']}"
        print(line)
        if mlx.get("active"):
            print(f"    mlx:       {human(mlx['active'])} active, {human(mlx.get('cache', 0))} cached"
                  f", {human(mlx.get('peak', 0))} peak")
        print(f"    process:   {human(mem.get('footprint'))} footprint, "
              f"{human(mem.get('resident'))} resident")
        for model_id, size in sorted((mem.get("models") or {}).items(), key=lambda kv: -kv[1]):
            print(f"    {model_id:20s} {human(size)}")
    print(f"  running:     {', '.join(reply['running']) or 'nothing'}")
    print(f"  downloaded:  {', '.join(reply['downloaded']) or 'nothing'}")
    for role, info in (reply.get("speech") or {}).items():
        # Older daemons sent a bare state string here.
        name = info.get("name", role) if isinstance(info, dict) else role
        state = info.get("state", info) if isinstance(info, dict) else info
        print(f"  {role + ':':12s} {state}  ({name})")
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

        from .macos.memory import human

        for group in reply.get("groups", []):
            models = group.get("models") or []
            if not models:
                continue
            print(f"\n{group['label']}")
            for model in models:
                caps = "".join([
                    "T" if model.get("tools") else "-",
                    "I" if model.get("images") else "-",
                    "R" if model.get("reasoning", "none") != "none" else "-",
                ])
                size = model.get("sizeGB")
                size_text = f"{size:>6.1f}G" if isinstance(size, (int, float)) else f"{'':>7s}"
                held = model.get("memory")
                suffix = f"   {human(held)}" if held else ""
                print(f"  {model['id']:20s} {size_text}  {caps:5s} {model['state']}{suffix}")

        print("\ncaps: T=tools I=images R=reasoning")
        print("speech models also answer to their role: tts, stt, or speech for both")
        return 0

    command = f"models.{args.action}"
    reply = _call({"command": command, "model": args.model})
    if not reply.get("ok"):
        print(f"error: {reply.get('error')}", file=sys.stderr)
        return 1

    model = reply["model"]
    print({
        "download": f"Downloading {model} — watch progress with: bigbro models list",
        "delete": f"Deleted {model} from disk.",
        "start": f"Started {model} — it is in memory and ready to answer.",
        "stop": f"Stopped {model} — the download is still on disk.",
    }[args.action])
    return 0


def _check_catalog() -> int:
    """Verifies every catalog repo id resolves on the Hub.

    Runs without a daemon and without downloading anything. This is the check that
    catches a repo that was renamed or never existed — the one class of catalog error
    that otherwise only surfaces as a failed download mid-request.
    """
    from huggingface_hub import HfApi
    from huggingface_hub.utils import HfHubHTTPError

    from .inference.catalog import EVERY_MODEL

    api = HfApi()
    failures = 0
    for model in EVERY_MODEL:
        try:
            api.model_info(model.repo)
            print(f"  ok    {model.id:22s} {model.repo}")
        except (HfHubHTTPError, OSError) as exc:
            failures += 1
            reason = getattr(getattr(exc, "response", None), "status_code", exc)
            print(f"  FAIL  {model.id:22s} {model.repo}  -> {reason}")

    print()
    if failures:
        print(f"{failures} of {len(EVERY_MODEL)} catalog entries did not resolve.")
        return 1
    print(f"All {len(EVERY_MODEL)} catalog entries resolve.")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    _configure_logging(args.verbose)

    if args.command == "serve":
        return cmd_serve(args)
    if args.command == "status":
        return cmd_status(args)
    if args.command == "shutdown":
        return cmd_shutdown(args)
    if args.command == "pair":
        return cmd_pair(args)
    if args.command == "models":
        return cmd_models(args)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
