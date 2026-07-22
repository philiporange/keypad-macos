"""Main application entry point for keypad macro background daemon and utility commands.

Provides CLI subcommands:
- run: starts the background daemon (with optional Rumps statusbar menu or headless mode)
- list-devices: prints details of all detected HID devices
- learn: prints raw report hex output from the device for a specified duration
- check-config: validates and displays a summary table of configured bindings
"""

import argparse
import logging
import signal
import sys
import threading
import time
from pathlib import Path
from typing import Union

from . import actions
from .config import Action, Config, ConfigError, load_config
from .events import KeyEvent, KnobEvent, ReportDecoder
from .listener import Listener, learn, list_devices

logger = logging.getLogger("keypad")


def _describe_action(action: Action) -> str:
    """Format an Action dataclass into a concise human-readable string."""
    if action.type == "macro":
        return f"macro({action.keys})"
    elif action.type == "media":
        return f"media({action.control})"
    elif action.type == "app":
        return f"app(name={action.name}, path={action.path})"
    elif action.type == "script":
        return f"script(path={action.path}, args={action.args})"
    elif action.type == "shell":
        return f"shell({action.command})"
    elif action.type == "aerospace":
        return f"aerospace({action.command})"
    return f"unknown({action.type})"


def handle_event(event: Union[KeyEvent, KnobEvent], cfg: Config) -> None:
    """Dispatch logical KeyEvent or KnobEvent to its matching configured Action."""
    if isinstance(event, KeyEvent):
        if not event.pressed:
            return
        for kb in cfg.keys:
            if kb.row == event.row and kb.col == event.col:
                logger.info("Key press (%d, %d) triggering %s", event.row, event.col, kb.action.type)
                actions.execute(kb.action)
                break
    elif isinstance(event, KnobEvent):
        for knb in cfg.knobs:
            if knb.index == event.index:
                act = None
                if event.direction == "cw":
                    act = knb.on_cw
                elif event.direction == "ccw":
                    act = knb.on_ccw
                elif event.direction == "press":
                    act = knb.on_press

                if act:
                    logger.info("Knob %d %s triggering %s", event.index, event.direction, act.type)
                    actions.execute(act)
                break


def run_headless(config_path: str) -> None:
    """Run macro keypad listener loop in headless mode (no statusbar)."""
    cfg = load_config(config_path)
    logging.basicConfig(level=getattr(logging, cfg.log_level, logging.INFO))
    logger.info("Starting keypad in headless mode...")

    decoder = ReportDecoder(rows=cfg.layout.rows, cols=cfg.layout.cols, knobs=cfg.layout.knobs)

    def on_event(ev):
        handle_event(ev, cfg)

    listener = Listener(cfg.device, decoder, on_event)
    listener.start()

    stop_event = threading.Event()

    def signal_handler(signum, frame):
        logger.info("Received signal %s, shutting down...", signum)
        stop_event.set()

    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    while not stop_event.is_set():
        stop_event.wait(timeout=1.0)

    listener.stop()
    logger.info("Keypad daemon stopped.")


ASSETS_DIR = Path(__file__).resolve().parent.parent / "assets"


def _statusbar_icon(cfg: Config) -> Union[str, None]:
    """The menu-bar icon path: the config's [app] icon if set, else the
    bundled asset, else None (rumps falls back to the app name)."""
    candidates = []
    if cfg.icon:
        candidates.append(Path(cfg.icon).expanduser())
    candidates.append(ASSETS_DIR / "statusbar.png")
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def run_statusbar(config_path: str) -> None:
    """Run macro keypad listener loop with macOS menu bar integration via rumps."""
    import rumps

    class KeypadApp(rumps.App):
        def __init__(self, cfg_path: str):
            self.config_path = cfg_path
            cfg = load_config(cfg_path)
            # template=True must be set at construction: the black/alpha icon
            # is recolored by macOS to match the menu bar appearance.
            # quit_button=None: the menu declares its own Quit item (which
            # stops the listener first), so rumps must not append another.
            super().__init__(
                "Keypad", icon=_statusbar_icon(cfg), template=True, quit_button=None
            )
            self.menu = ["Configure…", "Reload Config", "Quit"]
            self.listener = None
            self.web = None
            self.reload_config()

        def _on_config_saved(self):
            # Called from the web server's thread: refresh bindings and the
            # listener only — menu-bar UI (icon) is left to the main thread.
            try:
                self.cfg = load_config(self.config_path)
                self.setup_listener()
                logger.info("Configuration saved from web editor; bindings reloaded.")
            except Exception as e:
                logger.error("Failed to apply saved configuration: %s", e)

        @rumps.clicked("Configure…")
        def configure(self, _=None):
            import webbrowser

            from .webconfig import ConfigServer

            if self.web is None:
                self.web = ConfigServer(self.config_path, on_saved=self._on_config_saved)
                self.web.start()
                logger.info("Config editor at %s", self.web.url)
            webbrowser.open(self.web.url)

        def setup_listener(self):
            if self.listener:
                self.listener.stop()
            decoder = ReportDecoder(
                rows=self.cfg.layout.rows,
                cols=self.cfg.layout.cols,
                knobs=self.cfg.layout.knobs,
            )

            def on_event(ev):
                handle_event(ev, self.cfg)

            self.listener = Listener(self.cfg.device, decoder, on_event)
            self.listener.start()

        @rumps.clicked("Reload Config")
        def reload_config(self, _=None):
            try:
                self.cfg = load_config(self.config_path)
                logging.basicConfig(level=getattr(logging, self.cfg.log_level, logging.INFO), force=True)
                self.icon = _statusbar_icon(self.cfg)
                self.template = True
                self.setup_listener()
                logger.info("Configuration loaded/reloaded.")
            except Exception as e:
                logger.error("Failed to load configuration: %s", e)

        @rumps.clicked("Quit")
        def quit_app(self, _=None):
            if self.listener:
                self.listener.stop()
            if self.web:
                self.web.stop()
            rumps.quit_application()

    app = KeypadApp(config_path)
    app.run()


def cmd_check_config(config_path: str) -> None:
    """Validate configuration file and print summary table of device and action bindings."""
    try:
        cfg = load_config(config_path)
        print(f"Configuration valid: {config_path}")
        print(f"Device: 0x{cfg.device.vendor_id:04x}:0x{cfg.device.product_id:04x} "
              f"(usage_page={cfg.device.usage_page}, usage={cfg.device.usage})")
        print(f"Layout: {cfg.layout.rows}x{cfg.layout.cols} grid, {cfg.layout.knobs} knobs")
        print(f"App Settings: statusbar={cfg.statusbar}, log_level={cfg.log_level}\n")
        print("Key Bindings:")
        if not cfg.keys:
            print("  (None)")
        for kb in cfg.keys:
            print(f"  Row {kb.row}, Col {kb.col} -> {_describe_action(kb.action)}")

        print("\nKnob Bindings:")
        if not cfg.knobs:
            print("  (None)")
        for knb in cfg.knobs:
            if knb.on_cw:
                print(f"  Knob {knb.index} [cw] -> {_describe_action(knb.on_cw)}")
            if knb.on_ccw:
                print(f"  Knob {knb.index} [ccw] -> {_describe_action(knb.on_ccw)}")
            if knb.on_press:
                print(f"  Knob {knb.index} [press] -> {_describe_action(knb.on_press)}")
    except ConfigError as e:
        print(f"Configuration Error: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_configure(config_path: str, port: int, open_browser: bool) -> None:
    """Serve the browser config editor until interrupted."""
    import webbrowser

    from .webconfig import ConfigServer

    def on_saved():
        print("Saved. (The running daemon picks it up via its own editor or Reload Config.)")

    server = ConfigServer(config_path, on_saved=on_saved, port=port)
    server.start()
    print(f"Config editor: {server.url}  (Ctrl-C to stop)")
    if open_browser:
        webbrowser.open(server.url)
    try:
        signal.pause()
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()


def cmd_list_devices() -> None:
    """Print all detected HID devices."""
    try:
        devs = list_devices()
        if not devs:
            print("No HID devices found.")
            return
        print(f"Found {len(devs)} HID devices:")
        for d in devs:
            vid = d.get("vendor_id", 0)
            pid = d.get("product_id", 0)
            mfg = d.get("manufacturer_string", "Unknown")
            prod = d.get("product_string", "Unknown")
            up = d.get("usage_page")
            u = d.get("usage")
            print(f"  - 0x{vid:04x}:0x{pid:04x} | {mfg} - {prod} (usage_page: {up}, usage: {u})")
    except Exception as e:
        print(f"Error listing HID devices: {e}", file=sys.stderr)
        sys.exit(1)


def cmd_learn(config_path: str, seconds: float) -> None:
    """Read raw input report bytes from the device for a specified duration."""
    try:
        cfg = load_config(config_path)
        print(f"Listening for raw reports from device 0x{cfg.device.vendor_id:04x}:0x{cfg.device.product_id:04x} for {seconds}s...")
        for report in learn(cfg.device, seconds=seconds):
            print(f"Report: {report}")
    except Exception as e:
        print(f"Error in learn mode: {e}", file=sys.stderr)
        sys.exit(1)


def main() -> None:
    """Parse CLI arguments and dispatch subcommand execution."""
    default_config = str(Path.home() / ".config" / "keypad" / "keypad.toml")

    # Insert default 'run' subcommand if first arg is an option or omitted
    if len(sys.argv) == 1 or (len(sys.argv) > 1 and sys.argv[1].startswith("-")):
        sys.argv.insert(1, "run")

    parser = argparse.ArgumentParser(description="Keypad macro mapping daemon and utilities.")
    subparsers = parser.add_subparsers(dest="command", help="Subcommand to execute")

    # Subcommand 'run'
    run_parser = subparsers.add_parser("run", help="Run keypad macro background daemon")
    run_parser.add_argument("--config", default=default_config, help="Path to TOML configuration file")
    run_parser.add_argument("--no-statusbar", action="store_true", help="Force headless execution without menu bar statusbar")

    # Subcommand 'list-devices'
    subparsers.add_parser("list-devices", help="List all connected HID devices")

    # Subcommand 'learn'
    learn_parser = subparsers.add_parser("learn", help="Print raw report byte hex strings to map keypad buttons")
    learn_parser.add_argument("--config", default=default_config, help="Path to TOML configuration file")
    learn_parser.add_argument("--seconds", type=float, default=15.0, help="Duration in seconds to listen for reports")

    # Subcommand 'check-config'
    check_parser = subparsers.add_parser("check-config", help="Validate configuration file and print bindings summary")
    check_parser.add_argument("--config", default=default_config, help="Path to TOML configuration file")

    # Subcommand 'configure'
    cfg_parser = subparsers.add_parser("configure", help="Open the browser-based config editor")
    cfg_parser.add_argument("--config", default=default_config, help="Path to TOML configuration file")
    cfg_parser.add_argument("--port", type=int, default=0, help="Port to serve on (default: ephemeral)")
    cfg_parser.add_argument("--no-open", action="store_true", help="Do not open the browser automatically")

    args = parser.parse_args()

    if args.command == "run":
        try:
            cfg = load_config(args.config)
        except ConfigError as e:
            print(f"Configuration Error: {e}", file=sys.stderr)
            sys.exit(1)

        if cfg.statusbar and not args.no_statusbar:
            try:
                run_statusbar(args.config)
            except ImportError:
                logger.info("Rumps module not available; running in headless mode.")
                run_headless(args.config)
        else:
            run_headless(args.config)

    elif args.command == "list-devices":
        cmd_list_devices()

    elif args.command == "learn":
        cmd_learn(args.config, args.seconds)

    elif args.command == "check-config":
        cmd_check_config(args.config)

    elif args.command == "configure":
        cmd_configure(args.config, args.port, not args.no_open)


if __name__ == "__main__":
    main()
