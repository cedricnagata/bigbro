"""The interactive dashboard.

A control-socket client, not a daemon component. That split is deliberate: the
daemon's whole value is that it outlives the terminal, so a UI crash, a closed
window or an SSH drop must not take inference down with it. Everything here goes
through the same commands `bigbro pair` and `bigbro models` use, plus the
`subscribe` event stream for the pushes a poller could not do — chiefly a pairing
request, which has to appear on its own.

Runs in two places with one implementation: inside `bigbro serve` when it has a
terminal, and standalone via `bigbro ui` against a daemon started elsewhere.
"""

from __future__ import annotations

import asyncio
from typing import Any

from textual import on, work
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widget import Widget
from textual.widgets import (
    Button,
    DataTable,
    Footer,
    Header,
    Input,
    Label,
    RichLog,
    Static,
    TabbedContent,
    TabPane,
)

from .control import ControlClientError, send_command, subscribe
from .macos.memory import human

#: How often to re-sync authoritative state. Events drive the UI between these;
#: this only repairs drift after a dropped subscription or a missed event.
REFRESH_SECONDS = 5.0


class PairingPrompt(ModalScreen[bool]):
    """The prompt that replaces running `bigbro pair approve` in another shell.

    Enter approves because that is the overwhelmingly common answer — you are
    looking at the screen because you just tried to connect your own phone. Escape
    denies, and denial is also what a dismissed prompt means, so there is no way to
    leave a device hanging by accident.
    """

    BINDINGS = [
        Binding("enter", "approve", "Approve"),
        Binding("escape", "deny", "Deny"),
    ]

    def __init__(self, request: dict[str, Any]) -> None:
        super().__init__()
        self._request = request

    def compose(self) -> ComposeResult:
        device = self._request.get("deviceName", "Unknown device")
        app_name = self._request.get("appName", "Unknown app")
        device_id = str(self._request.get("deviceId", ""))
        required = self._request.get("requiredModels") or []

        with Vertical(id="pairing-dialog"):
            yield Label("Pairing request", id="pairing-title")
            yield Label(f"{device}", id="pairing-device")
            yield Label(f"app: {app_name}", classes="dim")
            yield Label(f"id:  {device_id[:16]}", classes="dim")
            if required:
                yield Label(f"wants: {', '.join(required)}", classes="dim")
            yield Label("")
            with Horizontal(id="pairing-buttons"):
                yield Button("Approve  (enter)", variant="success", id="approve")
                yield Button("Deny  (esc)", variant="error", id="deny")

    def action_approve(self) -> None:
        self.dismiss(True)

    def action_deny(self) -> None:
        self.dismiss(False)

    @on(Button.Pressed, "#approve")
    def _approve(self) -> None:
        self.dismiss(True)

    @on(Button.Pressed, "#deny")
    def _deny(self) -> None:
        self.dismiss(False)


class ConfirmPrompt(ModalScreen[bool]):
    """Confirmation for the destructive actions — removing a device or weights."""

    BINDINGS = [
        Binding("escape", "cancel", "Cancel"),
        Binding("enter", "confirm", "Confirm"),
    ]

    def __init__(self, question: str, detail: str = "") -> None:
        super().__init__()
        self._question = question
        self._detail = detail

    def compose(self) -> ComposeResult:
        with Vertical(id="pairing-dialog"):
            yield Label(self._question, id="pairing-title")
            if self._detail:
                yield Label(self._detail, classes="dim")
            yield Label("")
            with Horizontal(id="pairing-buttons"):
                yield Button("Confirm  (enter)", variant="error", id="confirm")
                yield Button("Cancel  (esc)", variant="primary", id="cancel")

    def action_confirm(self) -> None:
        self.dismiss(True)

    def action_cancel(self) -> None:
        self.dismiss(False)

    @on(Button.Pressed, "#confirm")
    def _confirm(self) -> None:
        self.dismiss(True)

    @on(Button.Pressed, "#cancel")
    def _cancel(self) -> None:
        self.dismiss(False)


class PaneTable(DataTable):
    """A DataTable that gives left/right back to the tab bar.

    DataTable binds them to column navigation, which means nothing here: the
    cursor is a row cursor, so there are no columns to move between. Leaving them
    bound would make left/right silently dead in the pane a person is most likely
    to press them in — the tabs are right above the table.
    """

    BINDINGS = [
        Binding("left", "app.previous_pane", "Previous pane", show=False),
        Binding("right", "app.next_pane", "Next pane", show=False),
    ]


class PaneLog(RichLog):
    """Same, for the log pane. Its left/right scroll horizontally, and it wraps."""

    BINDINGS = [
        Binding("left", "app.previous_pane", "Previous pane", show=False),
        Binding("right", "app.next_pane", "Next pane", show=False),
    ]


class BigBroApp(App):
    TITLE = "bigbro"

    CSS = """
    Screen { layers: base overlay; }

    #status-bar {
        dock: top;
        height: 1;
        background: $panel;
        color: $text;
        padding: 0 1;
    }

    .dim { color: $text-muted; }

    /* Modal screens centre their dialog and dim what is behind it, so an
       approval prompt reads as the thing being asked rather than as a panel
       that happened to appear in a corner. */
    PairingPrompt, ConfirmPrompt {
        align: center middle;
        background: $background 60%;
    }

    #pairing-dialog {
        width: 62;
        height: auto;
        padding: 1 2;
        background: $surface;
        border: thick $accent;
    }
    #pairing-title { text-style: bold; color: $accent; }
    #pairing-device { text-style: bold; }
    #pairing-buttons { height: auto; align: center middle; }
    #pairing-buttons Button { margin: 0 1; }

    DataTable { height: 1fr; }
    RichLog { height: 1fr; background: $surface; }

    #settings-pane { padding: 1 2; }
    #settings-pane Input { width: 24; margin: 0 0 1 0; }
    .setting-row { height: auto; margin: 0 0 1 0; }
    """

    # One key per verb rather than one key that guesses. A single toggle has to
    # infer intent from current state, which silently does the wrong thing the
    # moment that state is stale — and "delete" guessed wrong costs a re-download.
    BINDINGS = [
        Binding("q", "quit", "Quit"),
        Binding("r", "refresh", "Refresh"),
        Binding("d", "download_model", "Download"),
        Binding("s", "start_model", "Start"),
        Binding("x", "stop_model", "Stop"),
        Binding("delete,backspace", "delete_selected", "Delete"),
        Binding("a", "approve_selected", "Approve", show=False),
        # Switching panes from anywhere. Without these the only way back to the tab
        # bar is focus cycling, which is not obvious when the cursor is in a table.
        Binding("1", "show_pane('devices')", "Devices", show=False),
        Binding("2", "show_pane('models')", "Models", show=False),
        Binding("3", "show_pane('settings')", "Settings", show=False),
        Binding("4", "show_pane('log')", "Log", show=False),
        Binding("escape", "focus_pane", "Leave field", show=False),
        Binding("left", "previous_pane", "Prev pane", show=False),
        Binding("right", "next_pane", "Next pane", show=False),
    ]

    #: What takes focus when each pane is shown. Activating a tab leaves focus on
    #: the tab bar, so without this the arrow keys never reach the table the user
    #: is looking at and the selection appears frozen.
    PANE_FOCUS = {
        "devices": "#devices-table",
        "models": "#models-table",
        "settings": "#settings-pane",
        "log": "#log-view",
    }

    def __init__(self, socket_path=None, owns_daemon: bool = False) -> None:
        super().__init__()
        self._socket_path = socket_path
        # When the TUI is running inside `bigbro serve`, quitting should stop the
        # daemon too — the user started one thing and expects to stop one thing.
        # When attached via `bigbro ui`, quitting must leave it running.
        self.owns_daemon = owns_daemon
        #: Set by `serve` when the daemon task dies, so the reason survives the UI
        #: coming down and can be reported instead of a bare socket-not-found.
        self.daemon_error: BaseException | None = None
        self._status: dict[str, Any] = {}
        self._models: list[dict[str, Any]] = []
        self._devices: list[dict[str, Any]] = []
        self._settings: dict[str, Any] = {}
        self._prompting: set[str] = set()

    # MARK: - Layout

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static("connecting…", id="status-bar")
        with TabbedContent(initial="devices"):
            with TabPane("Devices", id="devices"):
                yield PaneTable(id="devices-table", cursor_type="row")
            with TabPane("Models", id="models"):
                yield PaneTable(id="models-table", cursor_type="row")
            with TabPane("Settings", id="settings"):
                with VerticalScroll(id="settings-pane", can_focus=True):
                    yield Label("Port", classes="dim")
                    yield Input(id="set-port", placeholder="8765")
                    yield Label("Keep the Mac awake while serving", classes="dim")
                    yield Input(id="set-keep-awake", placeholder="true / false")
                    yield Label("Log level", classes="dim")
                    yield Input(id="set-log-level", placeholder="DEBUG / INFO / WARNING / ERROR")
                    yield Static("", id="settings-message")
            with TabPane("Log", id="log"):
                yield PaneLog(id="log-view", markup=True, wrap=True, max_lines=2000)
        yield Footer()

    async def on_mount(self) -> None:
        devices = self._dash.query_one("#devices-table", DataTable)
        devices.add_columns("", "device", "app", "id", "models")

        models = self._dash.query_one("#models-table", DataTable)
        models.add_columns("model", "size", "caps", "state", "memory")

        self.listen_for_events()
        await self.action_refresh()
        self.set_interval(REFRESH_SECONDS, self.action_refresh)
        self._focus_active_pane()

    # MARK: - Pane focus

    def _focus_active_pane(self) -> None:
        """Puts the cursor where the user is looking."""
        try:
            active = self._dash.query_one(TabbedContent).active
        except Exception:
            return
        selector = self.PANE_FOCUS.get(active)
        if selector is None:
            return
        widget = self._find(selector, Widget)
        if widget is not None and widget.focusable:
            widget.focus()

    @on(TabbedContent.TabActivated)
    def _pane_activated(self, _event: TabbedContent.TabActivated) -> None:
        self._focus_active_pane()

    def action_show_pane(self, pane: str) -> None:
        tabs = self._find("TabbedContent", TabbedContent)
        if tabs is not None:
            tabs.active = pane
            self._focus_active_pane()

    def _step_pane(self, delta: int) -> None:
        order = list(self.PANE_FOCUS)
        tabs = self._find("TabbedContent", TabbedContent)
        if tabs is None:
            return
        current = order.index(tabs.active) if tabs.active in order else 0
        tabs.active = order[(current + delta) % len(order)]
        self._focus_active_pane()

    def action_next_pane(self) -> None:
        self._step_pane(1)

    def action_previous_pane(self) -> None:
        self._step_pane(-1)

    def action_focus_pane(self) -> None:
        """Returns focus from a text field to the pane around it."""
        self._focus_active_pane()

    def _find(self, selector: str, kind):
        """A dashboard widget, or None if it isn't there.

        Workers outlive the screen: a refresh queued behind an approval can land
        after the app has begun tearing down, and a hard `query_one` would raise
        NoMatches out of a background task. Nothing here is worth an error for —
        if the widget is gone, there is nothing to draw on.
        """
        if not self.is_running or not self.screen_stack:
            return None
        try:
            return self._dash.query_one(selector, kind)
        except Exception:
            return None

    @property
    def _dash(self):
        """The dashboard screen, regardless of what modal is stacked on top of it.

        `App.query_one` resolves against the *active* screen, so once a pairing
        prompt is up every dashboard lookup raises NoMatches — including the
        periodic refresh, which then takes the whole UI down at the exact moment
        someone is being asked a question.
        """
        return self.screen_stack[0]

    # MARK: - Daemon plumbing

    async def _call(self, command: str, **fields: Any) -> dict[str, Any]:
        try:
            return await send_command({"command": command, **fields}, self._socket_path)
        except ControlClientError as exc:
            self._log_line(f"[red]{exc}[/red]")
            return {"ok": False, "error": str(exc)}

    @work(exclusive=True)
    async def listen_for_events(self) -> None:
        """Streams daemon events for as long as the UI is up, reconnecting if dropped."""
        while True:
            try:
                async with subscribe(self._socket_path) as events:
                    self._log_line("[green]attached to daemon[/green]")
                    async for event in events:
                        self._handle_event(event)
            except ControlClientError as exc:
                self._log_line(f"[yellow]{exc}[/yellow]")
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                self._log_line(f"[red]event stream failed: {exc}[/red]")
            await asyncio.sleep(2.0)

    def _handle_event(self, event: dict[str, Any]) -> None:
        kind = event.get("event")

        if kind == "log":
            colour = {"WARNING": "yellow", "ERROR": "red", "DEBUG": "bright_black"}.get(
                event.get("level", ""), "white"
            )
            self._log_line(f"[{colour}]{event.get('message', '')}[/{colour}]")
            return

        if kind == "pairing.requested":
            self._prompt_for_pairing(event)
            return

        if kind in ("pairing.resolved", "peer.connected", "peer.disconnected"):
            self.call_later(self.action_refresh)
            return

        if kind in ("model.state", "download.progress"):
            self._apply_model_state(event)
            return

        if kind == "settings.changed":
            self._settings = event.get("settings", {})
            self._render_settings()

    # MARK: - Pairing

    def _prompt_for_pairing(self, request: dict[str, Any]) -> None:
        device_id = str(request.get("deviceId", ""))
        # The daemon re-announces on a retry; one prompt per device is enough.
        if device_id in self._prompting:
            return
        self._prompting.add(device_id)

        def decided(approved: bool | None) -> None:
            self._prompting.discard(device_id)
            self.resolve_pairing(device_id, bool(approved))

        self.push_screen(PairingPrompt(request), decided)

    @work
    async def resolve_pairing(self, device_id: str, approved: bool) -> None:
        command = "pair.approve" if approved else "pair.deny"
        reply = await self._call(command, deviceId=device_id)
        if reply.get("ok"):
            name = reply.get("deviceName", device_id[:8])
            verb = "approved" if approved else "denied"
            self._log_line(f"[bold]{verb}[/bold] {name}")
        await self.action_refresh()

    # MARK: - Refresh

    async def action_refresh(self) -> None:
        if not self.is_running:
            return
        status = await self._call("status")
        if status.get("ok"):
            self._status = status
            self._render_status()
            # A request that arrived while no UI was attached still needs answering.
            for pending in status.get("pending", []):
                self._prompt_for_pairing(pending)

        pairs = await self._call("pair.list")
        if pairs.get("ok"):
            self._devices = pairs.get("devices", [])
            self._render_devices(pairs.get("pending", []))

        models = await self._call("models.list")
        if models.get("ok"):
            self._models = models.get("models", []) + [
                {**entry, "family": "speech", "sizeGB": None, "tools": False,
                 "images": False, "reasoning": "none"}
                for entry in models.get("speech", [])
            ]
            self._render_models()

        settings = await self._call("settings.get")
        if settings.get("ok"):
            self._settings = settings.get("settings", {})
            self._render_settings()

    # MARK: - Rendering

    def _render_status(self) -> None:
        name = self._status.get("name", "?")
        port = self._status.get("port", "?")
        awake = "awake" if self._status.get("keepAwake") else "may sleep"
        paired = self._status.get("paired", 0)
        connected = len(self._status.get("connected", []))
        running = self._status.get("running", [])
        bar = (
            f" {name}  ·  port {port}  ·  {awake}  ·  "
            f"{connected}/{paired} connected  ·  "
            f"{len(running)} model(s) running"
        )
        mem = self._status.get("memory") or {}
        if mem.get("resident") is not None:
            share = (
                f" ({mem['resident'] / mem['total'] * 100:.0f}%)" if mem.get("total") else ""
            )
            bar += f"  ·  {human(mem['resident'])}{share}"
            if mem.get("pressure") and mem["pressure"] != "normal":
                bar += f" pressure {mem['pressure']}"
        bar_widget = self._find("#status-bar", Static)
        if bar_widget is not None:
            bar_widget.update(bar)

    def _render_devices(self, pending: list[dict[str, Any]]) -> None:
        table = self._find("#devices-table", DataTable)
        if table is None:
            return
        cursor = table.cursor_row
        table.clear()

        for request in pending:
            table.add_row(
                "?",
                request.get("deviceName", "?"),
                request.get("appName", ""),
                str(request.get("deviceId", ""))[:8],
                "awaiting approval",
                key=f"pending:{request.get('deviceId')}",
            )

        for device in self._devices:
            table.add_row(
                "*" if device.get("connected") else " ",
                device.get("name", "?"),
                device.get("appName", ""),
                str(device.get("deviceId", ""))[:8],
                ", ".join(device.get("requiredModels", [])) or "-",
                key=f"device:{device.get('deviceId')}",
            )

        if table.row_count and cursor is not None:
            table.move_cursor(row=min(cursor, table.row_count - 1))

    def _render_models(self) -> None:
        table = self._find("#models-table", DataTable)
        if table is None:
            return
        cursor = table.cursor_row
        table.clear()

        for model in self._models:
            size = model.get("sizeGB")
            caps = "".join([
                "T" if model.get("tools") else "-",
                "I" if model.get("images") else "-",
                "R" if model.get("reasoning", "none") != "none" else "-",
            ])
            held = (self._status.get("memory") or {}).get("models", {}).get(model.get("id"))
            table.add_row(
                model.get("id", "?"),
                f"{size:.1f}G" if isinstance(size, (int, float)) else "-",
                caps,
                model.get("state", "?"),
                human(held) if held else "-",
                key=f"model:{model.get('id')}",
            )

        if table.row_count and cursor is not None:
            table.move_cursor(row=min(cursor, table.row_count - 1))

    def _apply_model_state(self, event: dict[str, Any]) -> None:
        """Updates one model's state cell in place.

        Rebuilding the table on every progress event would fight the cursor and
        flicker, and download progress arrives twice a second.
        """
        model_id = event.get("model")
        state = event.get("state")
        if event.get("event") == "download.progress" and not event.get("done"):
            total = event.get("total") or 0
            if total:
                state = f"downloading {round((event.get('fraction') or 0) * 100)}%"

        for model in self._models:
            if model.get("id") == model_id:
                model["state"] = state or model.get("state")
                break

        table = self._find("#models-table", DataTable)
        if table is None:
            return
        try:
            table.update_cell(f"model:{model_id}", table.columns[-1].key, state or "?")
        except Exception:
            # Row not present yet (a speech model, or a race with a rebuild).
            pass

    def _render_settings(self) -> None:
        port = self._find("#set-port", Input)
        if not self._settings or port is None:
            return
        port.value = str(self._settings.get("port", ""))
        self._find("#set-keep-awake", Input).value = str(
            self._settings.get("keep_awake", "")
        ).lower()
        self._find("#set-log-level", Input).value = str(self._settings.get("log_level", ""))

    def _log_line(self, markup: str) -> None:
        view = self._find("#log-view", RichLog)
        if view is not None:
            view.write(markup)

    # MARK: - Row actions

    def _selected_key(self, table_id: str) -> str | None:
        table = self._dash.query_one(table_id, DataTable)
        if not table.row_count:
            return None
        try:
            row_key, _ = table.coordinate_to_cell_key((table.cursor_row, 0))
            return str(row_key.value)
        except Exception:
            return None

    async def action_approve_selected(self) -> None:
        if self._dash.query_one(TabbedContent).active != "devices":
            return
        key = self._selected_key("#devices-table")
        if key and key.startswith("pending:"):
            self.resolve_pairing(key.split(":", 1)[1], True)

    async def action_delete_selected(self) -> None:
        """Deletes the selected model's weights, or forgets the selected device.

        Both are destructive and irreversible over a slow download, so both
        confirm first.
        """
        active = self._dash.query_one(TabbedContent).active
        key = self._selected_key(f"#{active}-table") if active in ("devices", "models") else None
        if not key:
            return

        if key.startswith("device:"):
            device_id = key.split(":", 1)[1]
            confirmed = await self.push_screen_wait(
                ConfirmPrompt("Forget this device?", "It will need approval to reconnect.")
            )
            if confirmed:
                await self._call("pair.remove", deviceId=device_id)
                await self.action_refresh()

        elif key.startswith("model:"):
            model_id = key.split(":", 1)[1]
            confirmed = await self.push_screen_wait(
                ConfirmPrompt(f"Delete {model_id} from disk?", "The download will have to be repeated.")
            )
            if confirmed:
                await self._call("models.delete", model=model_id)
                await self.action_refresh()

    def _selected_model(self) -> str | None:
        """The model id under the cursor, or None if the Models pane isn't showing one."""
        if self._dash.query_one(TabbedContent).active != "models":
            return None
        key = self._selected_key("#models-table")
        if not key or not key.startswith("model:"):
            return None
        return key.split(":", 1)[1]

    async def action_download_model(self) -> None:
        model_id = self._selected_model()
        if model_id is None:
            return
        await self._call("models.download", model=model_id)
        await self.action_refresh()

    async def action_start_model(self) -> None:
        """Loads the weights into memory.

        Downloads first if they aren't on disk — the daemon does that anyway when a
        request needs a model it doesn't have, so refusing here would be a rule the
        wire protocol doesn't share.
        """
        model_id = self._selected_model()
        if model_id is None:
            return
        await self._call("models.start", model=model_id)
        await self.action_refresh()

    async def action_stop_model(self) -> None:
        model_id = self._selected_model()
        if model_id is None:
            return
        await self._call("models.stop", model=model_id)
        await self.action_refresh()

    # MARK: - Settings edits

    @on(Input.Submitted)
    async def _setting_submitted(self, event: Input.Submitted) -> None:
        key = {
            "set-port": "port",
            "set-keep-awake": "keep_awake",
            "set-log-level": "log_level",
        }.get(event.input.id or "")
        if key is None:
            return

        reply = await self._call("settings.set", key=key, value=event.value)
        message = self._dash.query_one("#settings-message", Static)
        if reply.get("ok"):
            message.update(f"[green]{reply.get('message', 'saved')}[/green]")
            self._settings = reply.get("settings", self._settings)
        else:
            message.update(f"[red]{reply.get('error', 'failed')}[/red]")
        self._render_settings()


async def run_dashboard(socket_path=None, owns_daemon: bool = False) -> None:
    await BigBroApp(socket_path=socket_path, owns_daemon=owns_daemon).run_async()
