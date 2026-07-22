"""HID listener and background monitoring thread for macro keypad events.

This module provides device listing, a learning generator for recording raw hex reports, and the
Listener class which manages a background thread to read HID reports, decode events, trigger callbacks,
and automatically handle device disconnections with exponential backoff reconnect attempts.
"""

import logging
import threading
import time
from typing import Any, Callable, Generator, List, Optional, Union

from .config import Device
from .events import KeyEvent, KnobEvent, ReportDecoder

logger = logging.getLogger(__name__)


def list_devices() -> List[dict]:
    """Enumerate and return all connected HID devices."""
    import hid
    return hid.enumerate()


def _open_hid_device(hid_module: Any, device_cfg: Device) -> Any:
    """Helper to open an HID device using vendor_id, product_id, and optional usage page/usage filters."""
    dev = hid_module.device()
    if device_cfg.usage_page is not None or device_cfg.usage is not None:
        devices = hid_module.enumerate(device_cfg.vendor_id, device_cfg.product_id)
        target_path = None
        for info in devices:
            match_up = (device_cfg.usage_page is None) or (info.get("usage_page") == device_cfg.usage_page)
            match_u = (device_cfg.usage is None) or (info.get("usage") == device_cfg.usage)
            if match_up and match_u:
                target_path = info.get("path")
                break
        if target_path:
            dev.open_path(target_path)
            return dev
    dev.open(device_cfg.vendor_id, device_cfg.product_id)
    return dev


def learn(device_cfg: Device, seconds: float = 15.0) -> Generator[str, None, None]:
    """Generator yielding formatted hex string reports from the device for a duration of `seconds`."""
    import hid
    dev = _open_hid_device(hid, device_cfg)
    start_time = time.time()
    try:
        while time.time() - start_time < seconds:
            data = dev.read(64, timeout_ms=100)
            if data:
                yield bytes(data).hex(" ")
    finally:
        try:
            dev.close()
        except Exception:
            pass


class Listener:
    """Background listener that monitors HID report input, decodes events, and triggers actions."""

    def __init__(
        self,
        device_cfg: Device,
        decoder: ReportDecoder,
        on_event: Callable[[Union[KeyEvent, KnobEvent]], None],
    ):
        self.device_cfg = device_cfg
        self.decoder = decoder
        self.on_event = on_event
        self._thread: Optional[threading.Thread] = None
        self._running = False

    def start(self) -> None:
        """Start the background HID reading loop thread."""
        if self._running:
            return
        self._running = True
        self._thread = threading.Thread(target=self._run_loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        """Stop the background HID reading loop thread."""
        self._running = False
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=2.0)

    def _run_loop(self) -> None:
        backoff = 1.0
        max_backoff = 30.0
        connected = False

        while self._running:
            dev = None
            try:
                import hid
                dev = _open_hid_device(hid, self.device_cfg)
                if not connected:
                    logger.info("Connected to device (0x%04x:0x%04x)", self.device_cfg.vendor_id, self.device_cfg.product_id)
                    connected = True
                backoff = 1.0

                while self._running:
                    data = dev.read(64, timeout_ms=200)
                    if data:
                        event = self.decoder.decode(bytes(data))
                        if event is not None:
                            try:
                                self.on_event(event)
                            except Exception as e:
                                logger.error("Error in on_event handler: %s", e)
            except Exception as e:
                if connected:
                    logger.warning("Device disconnected or read failure: %s", e)
                    connected = False
                else:
                    logger.debug("Device connection attempt failed: %s", e)

                if dev:
                    try:
                        dev.close()
                    except Exception:
                        pass

                if self._running:
                    logger.info("Reconnecting in %.1fs...", backoff)
                    slept = 0.0
                    while slept < backoff and self._running:
                        time.sleep(0.1)
                        slept += 0.1
                    backoff = min(backoff * 2.0, max_backoff)
