"""Native macOS AppKit configuration window for Keypad.

Provides a graphical configuration editor window using PyObjC (AppKit/Foundation)
to edit keypad layouts, device parameters, system preferences, and action bindings.
"""

import json
import logging
import os
import shlex
import tempfile
import tomllib
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

import AppKit
import Foundation
import objc

from . import config, loginitem, tomlio

logger = logging.getLogger(__name__)


def show_alert(message: str, title: str = "Configuration Error") -> None:
    """Display an NSAlert warning modal with the given message."""
    alert = AppKit.NSAlert.alloc().init()
    alert.setMessageText_(title)
    alert.setInformativeText_(str(message))
    alert.setAlertStyle_(AppKit.NSAlertStyleWarning)
    alert.addButtonWithTitle_("OK")
    alert.runModal()


def parse_hex_or_int(val_str: str, name: str, allow_none: bool = False) -> Optional[int]:
    """Parse hex or decimal string into integer value."""
    s = val_str.strip()
    if not s:
        if allow_none:
            return None
        raise ValueError(f"{name} is required")
    try:
        return int(s, 0)
    except ValueError:
        try:
            return int(s, 16)
        except ValueError:
            raise ValueError(f"{name} must be a valid integer or hex string (e.g. 0x1234), got '{val_str}'")


def parse_pos_int(val_str: str, name: str) -> int:
    """Parse string into a positive integer (> 0)."""
    s = val_str.strip()
    if not s:
        raise ValueError(f"{name} is required")
    try:
        val = int(s, 10)
        if val <= 0:
            raise ValueError
        return val
    except ValueError:
        raise ValueError(f"{name} must be a positive integer, got '{val_str}'")


def parse_nonneg_int(val_str: str, name: str) -> int:
    """Parse string into a non-negative integer (>= 0)."""
    s = val_str.strip()
    if not s:
        raise ValueError(f"{name} is required")
    try:
        val = int(s, 10)
        if val < 0:
            raise ValueError
        return val
    except ValueError:
        raise ValueError(f"{name} must be a non-negative integer, got '{val_str}'")


class _WindowOwner(Foundation.NSObject):
    """Target object for AppKit control actions."""

    def initWithController_(self, controller: Any):
        self = objc.super(_WindowOwner, self).init()
        if self is not None:
            self._controller = controller
        return self

    @objc.IBAction
    def savePressed_(self, sender: Any):
        if self._controller:
            self._controller.on_save_pressed()

    @objc.IBAction
    def revertPressed_(self, sender: Any):
        if self._controller:
            self._controller.on_revert_pressed()

    @objc.IBAction
    def actionTypeChanged_(self, sender: Any):
        if self._controller:
            self._controller.on_action_type_changed(sender)

    @objc.IBAction
    def keyButtonClicked_(self, sender: Any):
        if self._controller:
            self._controller.on_key_button_clicked(sender)

    @objc.IBAction
    def knobSelectionChanged_(self, sender: Any):
        if self._controller:
            self._controller.on_knob_selection_changed(sender)


def _add_tf(parent: AppKit.NSView, label: str, y: float, w: float = 480, lw: float = 140) -> AppKit.NSTextField:
    lbl = AppKit.NSTextField.labelWithString_(label)
    lbl.setFrame_(Foundation.NSMakeRect(0, y, lw, 20))
    parent.addSubview_(lbl)
    tf = AppKit.NSTextField.alloc().initWithFrame_(Foundation.NSMakeRect(0, y - 26, w, 24))
    parent.addSubview_(tf)
    return tf


def _add_popup(parent: AppKit.NSView, label: str, y: float, items: List[str], w: float = 220) -> AppKit.NSPopUpButton:
    lbl = AppKit.NSTextField.labelWithString_(label)
    lbl.setFrame_(Foundation.NSMakeRect(0, y, 140, 20))
    parent.addSubview_(lbl)
    pop = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(Foundation.NSMakeRect(0, y - 26, w, 24), False)
    pop.addItemsWithTitles_(items)
    parent.addSubview_(pop)
    return pop


def _create_scrollable_textview(frame: Foundation.NSRect) -> Tuple[AppKit.NSScrollView, AppKit.NSTextView]:
    scroll_view = AppKit.NSScrollView.alloc().initWithFrame_(frame)
    scroll_view.setHasVerticalScroller_(True)
    scroll_view.setHasHorizontalScroller_(False)
    scroll_view.setAutohidesScrollers_(True)
    scroll_view.setBorderType_(AppKit.NSBezelBorder)
    content_size = scroll_view.contentSize()
    text_view = AppKit.NSTextView.alloc().initWithFrame_(
        Foundation.NSMakeRect(0, 0, content_size.width, content_size.height)
    )
    text_view.setMinSize_(Foundation.NSMakeSize(0.0, content_size.height))
    text_view.setMaxSize_(Foundation.NSMakeSize(float("inf"), float("inf")))
    text_view.setVerticallyResizable_(True)
    text_view.setHorizontallyResizable_(False)
    text_view.setAutoresizingMask_(AppKit.NSViewWidthSizable)
    text_view.setFont_(AppKit.NSFont.userFixedPitchFontOfSize_(12.0))
    scroll_view.setDocumentView_(text_view)
    return scroll_view, text_view


class ActionEditorPanel:
    """Component managing action type selection and parameter controls."""

    ACTION_TYPES = [
        "(none)",
        "macro",
        "media",
        "app",
        "script",
        "shell",
        "aerospace",
        "url",
        "text",
        "applescript",
        "shortcut",
        "system",
        "volume",
        "notification",
        "sequence",
    ]

    def __init__(self, parent_view: AppKit.NSView, frame: Foundation.NSRect, owner: _WindowOwner):
        self.view = AppKit.NSView.alloc().initWithFrame_(frame)
        parent_view.addSubview_(self.view)
        h, w = frame.size.height, frame.size.width

        lbl_act = AppKit.NSTextField.labelWithString_("Action")
        lbl_act.setFrame_(Foundation.NSMakeRect(0, h - 30, 60, 24))
        self.view.addSubview_(lbl_act)

        self.action_popup = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(
            Foundation.NSMakeRect(70, h - 32, 180, 24), False
        )
        self.action_popup.addItemsWithTitles_(self.ACTION_TYPES)
        self.action_popup.setTarget_(owner)
        self.action_popup.setAction_("actionTypeChanged:")
        self.view.addSubview_(self.action_popup)

        param_h = max(h - 40, 10)
        self.param_container = AppKit.NSView.alloc().initWithFrame_(Foundation.NSMakeRect(0, 0, w, param_h))
        self.view.addSubview_(self.param_container)
        self.type_views: Dict[str, AppKit.NSView] = {}

        top_y = param_h - 22

        def new_view(t: str) -> AppKit.NSView:
            v = AppKit.NSView.alloc().initWithFrame_(Foundation.NSMakeRect(0, 0, w, param_h))
            self.type_views[t] = v
            self.param_container.addSubview_(v)
            return v

        # Subviews
        self.tf_macro_keys = _add_tf(new_view("macro"), "Chords (comma-separated)", top_y)
        self.popup_media_control = _add_popup(new_view("media"), "Control", top_y, sorted(config.VALID_MEDIA_CONTROLS))

        v_app = new_view("app")
        self.tf_app_name = _add_tf(v_app, "App name", top_y, w=300)
        self.tf_app_path = _add_tf(v_app, "Path (optional)", top_y - 56)

        v_script = new_view("script")
        self.tf_script_path = _add_tf(v_script, "Path", top_y)
        self.tf_script_args = _add_tf(v_script, "Arguments", top_y - 56)

        self.tf_shell_cmd = _add_tf(new_view("shell"), "Command", top_y)
        self.tf_aerospace_cmd = _add_tf(new_view("aerospace"), "Command", top_y)
        self.tf_url = _add_tf(new_view("url"), "URL", top_y)
        self.tf_text = _add_tf(new_view("text"), "Text to type", top_y)

        v_as = new_view("applescript")
        lbl = AppKit.NSTextField.labelWithString_("Source")
        lbl.setFrame_(Foundation.NSMakeRect(0, top_y, 100, 20))
        v_as.addSubview_(lbl)
        as_h = max(param_h - 35, 60)
        as_scroll, self.tv_applescript = _create_scrollable_textview(Foundation.NSMakeRect(0, top_y - as_h, 580, as_h))
        v_as.addSubview_(as_scroll)

        self.tf_shortcut_name = _add_tf(new_view("shortcut"), "Shortcut name", top_y, w=300)
        self.popup_system_cmd = _add_popup(new_view("system"), "Command", top_y, sorted(config.VALID_SYSTEM_COMMANDS))
        self.tf_volume_level = _add_tf(new_view("volume"), "Level (0-100)", top_y, w=100)

        v_notif = new_view("notification")
        self.tf_notif_title = _add_tf(v_notif, "Title (optional)", top_y, w=300)
        self.tf_notif_text = _add_tf(v_notif, "Message", top_y - 56)

        v_seq = new_view("sequence")
        lbl1 = AppKit.NSTextField.labelWithString_("Steps (TOML array of inline tables)")
        lbl1.setFrame_(Foundation.NSMakeRect(0, top_y, 300, 20))
        v_seq.addSubview_(lbl1)
        seq_h = max(param_h - 95, 50)
        seq_scroll, self.tv_sequence = _create_scrollable_textview(Foundation.NSMakeRect(0, top_y - seq_h, 580, seq_h))
        v_seq.addSubview_(seq_scroll)
        lbl2 = AppKit.NSTextField.labelWithString_("Delay between steps (s)")
        lbl2.setFrame_(Foundation.NSMakeRect(0, top_y - seq_h - 22, 200, 20))
        v_seq.addSubview_(lbl2)
        self.tf_sequence_delay = AppKit.NSTextField.alloc().initWithFrame_(
            Foundation.NSMakeRect(0, top_y - seq_h - 48, 100, 24)
        )
        v_seq.addSubview_(self.tf_sequence_delay)

        self.update_visible_type()

    def update_visible_type(self) -> None:
        selected = self.action_popup.titleOfSelectedItem()
        for t, v in self.type_views.items():
            v.setHidden_(t != selected)

    def load_action(self, action: Optional[dict]) -> None:
        if not action or not isinstance(action, dict):
            self.action_popup.selectItemWithTitle_("(none)")
            self.update_visible_type()
            return

        act_type = action.get("type", "(none)")
        if act_type not in self.ACTION_TYPES:
            act_type = "(none)"

        self.action_popup.selectItemWithTitle_(act_type)
        self.update_visible_type()

        if act_type == "macro":
            keys = action.get("keys", [])
            self.tf_macro_keys.setStringValue_(", ".join(keys) if isinstance(keys, list) else str(keys or ""))
        elif act_type == "media":
            c = action.get("control", "")
            if c in config.VALID_MEDIA_CONTROLS:
                self.popup_media_control.selectItemWithTitle_(c)
        elif act_type == "app":
            self.tf_app_name.setStringValue_(action.get("name") or "")
            self.tf_app_path.setStringValue_(action.get("path") or "")
        elif act_type == "script":
            self.tf_script_path.setStringValue_(action.get("path") or "")
            args = action.get("args", [])
            self.tf_script_args.setStringValue_(
                shlex.join(args) if hasattr(shlex, "join") and isinstance(args, list) else " ".join(args) if isinstance(args, list) else str(args or "")
            )
        elif act_type == "shell":
            self.tf_shell_cmd.setStringValue_(action.get("command") or "")
        elif act_type == "aerospace":
            self.tf_aerospace_cmd.setStringValue_(action.get("command") or "")
        elif act_type == "url":
            self.tf_url.setStringValue_(action.get("url") or "")
        elif act_type == "text":
            self.tf_text.setStringValue_(action.get("text") or "")
        elif act_type == "applescript":
            self.tv_applescript.setString_(action.get("source") or "")
        elif act_type == "shortcut":
            self.tf_shortcut_name.setStringValue_(action.get("name") or "")
        elif act_type == "system":
            cmd = action.get("command", "")
            if cmd in config.VALID_SYSTEM_COMMANDS:
                self.popup_system_cmd.selectItemWithTitle_(cmd)
        elif act_type == "volume":
            self.tf_volume_level.setStringValue_(str(action.get("level", 50)))
        elif act_type == "notification":
            self.tf_notif_title.setStringValue_(action.get("title") or "")
            self.tf_notif_text.setStringValue_(action.get("text") or "")
        elif act_type == "sequence":
            steps = action.get("steps", [])
            items = [tomlio._format_value(s) for s in steps]
            self.tv_sequence.setString_(f"[{', '.join(items)}]")
            delay = action.get("delay", 0.0)
            self.tf_sequence_delay.setStringValue_(str(delay) if delay else "")

    def collect(self) -> Optional[dict]:
        act_type = self.action_popup.titleOfSelectedItem()
        if act_type == "(none)":
            return None

        if act_type == "macro":
            chords = [c.strip() for c in self.tf_macro_keys.stringValue().split(",") if c.strip()]
            if not chords:
                raise ValueError("Macro action requires at least one chord")
            return {"type": "macro", "keys": chords}
        elif act_type == "media":
            return {"type": "media", "control": self.popup_media_control.titleOfSelectedItem()}
        elif act_type == "app":
            name = self.tf_app_name.stringValue().strip()
            path = self.tf_app_path.stringValue().strip()
            if not name and not path:
                raise ValueError("App action requires name or path")
            res = {"type": "app"}
            if name:
                res["name"] = name
            if path:
                res["path"] = path
            return res
        elif act_type == "script":
            path = self.tf_script_path.stringValue().strip()
            if not path:
                raise ValueError("Script action requires path")
            args_raw = self.tf_script_args.stringValue().strip()
            res = {"type": "script", "path": path}
            if args_raw:
                res["args"] = shlex.split(args_raw)
            return res
        elif act_type == "shell":
            cmd = self.tf_shell_cmd.stringValue().strip()
            if not cmd:
                raise ValueError("Shell action requires command")
            return {"type": "shell", "command": cmd}
        elif act_type == "aerospace":
            cmd = self.tf_aerospace_cmd.stringValue().strip()
            if not cmd:
                raise ValueError("AeroSpace action requires command")
            return {"type": "aerospace", "command": cmd}
        elif act_type == "url":
            u = self.tf_url.stringValue().strip()
            if not u:
                raise ValueError("URL action requires URL")
            return {"type": "url", "url": u}
        elif act_type == "text":
            txt = self.tf_text.stringValue().strip()
            if not txt:
                raise ValueError("Text action requires text")
            return {"type": "text", "text": txt}
        elif act_type == "applescript":
            src = self.tv_applescript.string().strip()
            if not src:
                raise ValueError("AppleScript action requires source code")
            return {"type": "applescript", "source": src}
        elif act_type == "shortcut":
            name = self.tf_shortcut_name.stringValue().strip()
            if not name:
                raise ValueError("Shortcut action requires name")
            return {"type": "shortcut", "name": name}
        elif act_type == "system":
            return {"type": "system", "command": self.popup_system_cmd.titleOfSelectedItem()}
        elif act_type == "volume":
            try:
                val = int(self.tf_volume_level.stringValue().strip(), 10)
                if not (0 <= val <= 100):
                    raise ValueError
            except Exception:
                raise ValueError("Volume action requires integer level between 0 and 100")
            return {"type": "volume", "level": val}
        elif act_type == "notification":
            msg = self.tf_notif_text.stringValue().strip()
            if not msg:
                raise ValueError("Notification action requires message text")
            title = self.tf_notif_title.stringValue().strip()
            res = {"type": "notification", "text": msg}
            if title:
                res["title"] = title
            return res
        elif act_type == "sequence":
            raw = self.tv_sequence.string().strip()
            if not raw:
                raise ValueError("Sequence action requires steps")
            try:
                parsed = tomllib.loads("steps = " + raw)
                steps_list = parsed.get("steps")
                if not isinstance(steps_list, list) or not steps_list:
                    raise ValueError
            except Exception as e:
                raise ValueError(f"Invalid TOML steps array in sequence action: {e}")
            delay_raw = self.tf_sequence_delay.stringValue().strip()
            delay = 0.0
            if delay_raw:
                try:
                    delay = float(delay_raw)
                    if delay < 0:
                        raise ValueError
                except Exception:
                    raise ValueError("Delay must be a non-negative number of seconds")
            res = {"type": "sequence", "steps": steps_list}
            if delay > 0:
                res["delay"] = delay
            return res

        return None


class ConfigWindowController:
    """Public facade for managing the native macOS configuration window."""

    def __init__(self, config_path: str, on_saved: Optional[Callable[[], None]] = None):
        self.config_path = str(Path(config_path).expanduser().resolve())
        self.on_saved = on_saved
        self._window: Optional[AppKit.NSWindow] = None
        self._owner: Optional[_WindowOwner] = None

        self.model: Dict[str, Any] = {}
        self._selected_key: Optional[Tuple[int, int]] = None
        self._selected_knob_index: Optional[int] = None
        self._selected_knob_event: Optional[str] = None
        self._key_buttons: Dict[Tuple[int, int], AppKit.NSButton] = {}

    def show(self) -> None:
        """Create window lazily on first call and bring to front."""
        if self._window is None:
            self.reload_from_disk()
            self._create_window()
        AppKit.NSApplication.sharedApplication().activateIgnoringOtherApps_(True)
        self._window.makeKeyAndOrderFront_(None)

    def reload_from_disk(self) -> None:
        """Load configuration from disk into self.model."""
        cfg = config.load_config(self.config_path)

        is_login = False
        try:
            is_login = loginitem.is_enabled()
        except Exception as e:
            logger.warning("Error checking login item status: %s", e)

        init_launch = bool(cfg.launch_at_login or is_login)
        rows, cols, knobs_count = cfg.layout.rows, cfg.layout.cols, cfg.layout.knobs

        key_map = {(k.row, k.col): tomlio.action_to_dict(k.action) for k in cfg.keys}
        keys_model = [{"row": r, "col": c, "action": key_map.get((r, c))} for r in range(rows) for c in range(cols)]

        knob_map = {kn.index: kn for kn in cfg.knobs}
        knobs_model = []
        for idx in range(knobs_count):
            kn_obj = knob_map.get(idx)
            knobs_model.append({
                "index": idx,
                "on_cw": tomlio.action_to_dict(kn_obj.on_cw) if kn_obj else None,
                "on_ccw": tomlio.action_to_dict(kn_obj.on_ccw) if kn_obj else None,
                "on_press": tomlio.action_to_dict(kn_obj.on_press) if kn_obj else None,
            })

        self.model = {
            "device": {
                "vendor_id": cfg.device.vendor_id,
                "product_id": cfg.device.product_id,
                "usage_page": cfg.device.usage_page,
                "usage": cfg.device.usage,
                "protocol": cfg.device.protocol,
            },
            "layout": {"rows": rows, "cols": cols, "knobs": knobs_count},
            "app": {
                "statusbar": cfg.statusbar,
                "log_level": cfg.log_level,
                "icon": cfg.icon,
                "launch_at_login": init_launch,
            },
            "keys": keys_model,
            "knobs": knobs_model,
        }

        if self._window is not None:
            self.populate_ui()

    def get_key_action(self, r: int, c: int) -> Optional[dict]:
        for k in self.model.get("keys", []):
            if k["row"] == r and k["col"] == c:
                return k.get("action")
        return None

    def set_key_action(self, r: int, c: int, action: Optional[dict]) -> None:
        for k in self.model.get("keys", []):
            if k["row"] == r and k["col"] == c:
                k["action"] = action
                return
        self.model.setdefault("keys", []).append({"row": r, "col": c, "action": action})

    def get_knob_action(self, idx: int, evt_key: str) -> Optional[dict]:
        for kn in self.model.get("knobs", []):
            if kn["index"] == idx:
                return kn.get(evt_key)
        return None

    def set_knob_action(self, idx: int, evt_key: str, action: Optional[dict]) -> None:
        for kn in self.model.get("knobs", []):
            if kn["index"] == idx:
                kn[evt_key] = action
                return
        new_kn = {"index": idx, "on_cw": None, "on_ccw": None, "on_press": None}
        new_kn[evt_key] = action
        self.model.setdefault("knobs", []).append(new_kn)

    def _create_window(self) -> None:
        self._owner = _WindowOwner.alloc().initWithController_(self)

        rect = Foundation.NSMakeRect(100, 100, 740, 620)
        style_mask = (
            AppKit.NSWindowStyleMaskTitled
            | AppKit.NSWindowStyleMaskClosable
            | AppKit.NSWindowStyleMaskMiniaturizable
        )
        self._window = AppKit.NSWindow.alloc().initWithContentRect_styleMask_backing_defer_(
            rect, style_mask, AppKit.NSBackingStoreBuffered, False
        )
        self._window.setTitle_("Keypad Configuration")
        self._window.setReleasedWhenClosed_(False)

        cv = self._window.contentView()

        self.btn_revert = AppKit.NSButton.alloc().initWithFrame_(Foundation.NSMakeRect(525, 10, 95, 30))
        self.btn_revert.setButtonType_(AppKit.NSButtonTypeMomentaryPushIn)
        self.btn_revert.setTitle_("Revert")
        self.btn_revert.setTarget_(self._owner)
        self.btn_revert.setAction_("revertPressed:")
        cv.addSubview_(self.btn_revert)

        self.btn_save = AppKit.NSButton.alloc().initWithFrame_(Foundation.NSMakeRect(630, 10, 95, 30))
        self.btn_save.setButtonType_(AppKit.NSButtonTypeMomentaryPushIn)
        self.btn_save.setTitle_("Save")
        self.btn_save.setKeyEquivalent_("\r")
        self.btn_save.setTarget_(self._owner)
        self.btn_save.setAction_("savePressed:")
        cv.addSubview_(self.btn_save)

        self.tab_view = AppKit.NSTabView.alloc().initWithFrame_(Foundation.NSMakeRect(15, 45, 710, 565))
        cv.addSubview_(self.tab_view)

        # Tab 1: General
        item_gen = AppKit.NSTabViewItem.alloc().initWithIdentifier_("general")
        item_gen.setLabel_("General")
        self.v_general = AppKit.NSView.alloc().initWithFrame_(Foundation.NSMakeRect(0, 0, 690, 520))
        item_gen.setView_(self.v_general)
        self._setup_general_tab()
        self.tab_view.addTabViewItem_(item_gen)

        # Tab 2: Keys
        item_keys = AppKit.NSTabViewItem.alloc().initWithIdentifier_("keys")
        item_keys.setLabel_("Keys")
        self.v_keys = AppKit.NSView.alloc().initWithFrame_(Foundation.NSMakeRect(0, 0, 690, 520))
        item_keys.setView_(self.v_keys)
        self._setup_keys_tab()
        self.tab_view.addTabViewItem_(item_keys)

        # Tab 3: Knobs
        item_knobs = AppKit.NSTabViewItem.alloc().initWithIdentifier_("knobs")
        item_knobs.setLabel_("Knobs")
        self.v_knobs = AppKit.NSView.alloc().initWithFrame_(Foundation.NSMakeRect(0, 0, 690, 520))
        item_knobs.setView_(self.v_knobs)
        self._setup_knobs_tab()
        self.tab_view.addTabViewItem_(item_knobs)

        self.populate_ui()

    def _setup_general_tab(self) -> None:
        v = self.v_general

        self.cb_launch_at_login = AppKit.NSButton.alloc().initWithFrame_(Foundation.NSMakeRect(30, 470, 300, 24))
        self.cb_launch_at_login.setButtonType_(AppKit.NSButtonTypeSwitch)
        self.cb_launch_at_login.setTitle_("Launch at login")
        v.addSubview_(self.cb_launch_at_login)

        self.cb_statusbar = AppKit.NSButton.alloc().initWithFrame_(Foundation.NSMakeRect(30, 435, 300, 24))
        self.cb_statusbar.setButtonType_(AppKit.NSButtonTypeSwitch)
        self.cb_statusbar.setTitle_("Show menu bar icon")
        v.addSubview_(self.cb_statusbar)

        def label(text, x, y, w=120):
            lbl = AppKit.NSTextField.labelWithString_(text)
            lbl.setFrame_(Foundation.NSMakeRect(x, y, w, 20))
            v.addSubview_(lbl)
            return lbl

        def field(x, y, w):
            tf = AppKit.NSTextField.alloc().initWithFrame_(Foundation.NSMakeRect(x, y, w, 24))
            v.addSubview_(tf)
            return tf

        def header(text, y):
            lbl = label(text, 30, y, w=200)
            lbl.setFont_(AppKit.NSFont.boldSystemFontOfSize_(13.0))

        def separator(y):
            sep = AppKit.NSBox.alloc().initWithFrame_(Foundation.NSMakeRect(30, y, 630, 2))
            sep.setBoxType_(AppKit.NSBoxSeparator)
            v.addSubview_(sep)

        label("Log level", 30, 397)
        self.popup_log_level = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(
            Foundation.NSMakeRect(160, 395, 160, 24), False
        )
        self.popup_log_level.addItemsWithTitles_(["DEBUG", "INFO", "WARNING", "ERROR"])
        v.addSubview_(self.popup_log_level)

        separator(370)
        header("Device Settings", 340)

        label("Vendor ID", 30, 307)
        self.tf_vendor_id = field(160, 305, 140)
        label("Product ID", 330, 307)
        self.tf_product_id = field(450, 305, 140)

        label("Usage page", 30, 272)
        self.tf_usage_page = field(160, 270, 140)
        label("Usage", 330, 272)
        self.tf_usage = field(450, 270, 140)

        label("Protocol", 30, 237)
        self.popup_protocol = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(
            Foundation.NSMakeRect(160, 235, 140, 24), False
        )
        self.popup_protocol.addItemsWithTitles_(["vendor", "keyboard"])
        v.addSubview_(self.popup_protocol)

        separator(210)
        header("Grid Layout", 180)

        label("Rows", 30, 147, w=100)
        self.tf_rows = field(140, 145, 80)
        label("Cols", 240, 147, w=90)
        self.tf_cols = field(340, 145, 80)
        label("Knobs", 440, 147, w=90)
        self.tf_knobs = field(540, 145, 80)

    def _setup_keys_tab(self) -> None:
        v = self.v_keys
        self.grid_scroll = AppKit.NSScrollView.alloc().initWithFrame_(Foundation.NSMakeRect(15, 240, 660, 265))
        self.grid_scroll.setHasVerticalScroller_(True)
        self.grid_scroll.setHasHorizontalScroller_(True)
        self.grid_scroll.setAutohidesScrollers_(True)
        self.grid_scroll.setBorderType_(AppKit.NSBezelBorder)

        self.grid_container = AppKit.NSView.alloc().initWithFrame_(Foundation.NSMakeRect(0, 0, 640, 260))
        self.grid_scroll.setDocumentView_(self.grid_container)
        v.addSubview_(self.grid_scroll)
        self.keys_editor = ActionEditorPanel(v, Foundation.NSMakeRect(15, 10, 660, 220), self._owner)

    def _setup_knobs_tab(self) -> None:
        v = self.v_knobs
        self.popup_knob_index = _add_popup(v, "Knob", 475, [], w=140)
        self.popup_knob_index.setFrame_(Foundation.NSMakeRect(75, 475, 140, 24))
        self.popup_knob_index.setTarget_(self._owner)
        self.popup_knob_index.setAction_("knobSelectionChanged:")

        lbl_e = AppKit.NSTextField.labelWithString_("Event")
        lbl_e.setFrame_(Foundation.NSMakeRect(240, 475, 50, 24))
        v.addSubview_(lbl_e)
        self.popup_knob_event = AppKit.NSPopUpButton.alloc().initWithFrame_pullsDown_(
            Foundation.NSMakeRect(295, 475, 160, 24), False
        )
        self.popup_knob_event.addItemsWithTitles_(["Rotate CW", "Rotate CCW", "Press"])
        self.popup_knob_event.setTarget_(self._owner)
        self.popup_knob_event.setAction_("knobSelectionChanged:")
        v.addSubview_(self.popup_knob_event)

        sep = AppKit.NSBox.alloc().initWithFrame_(Foundation.NSMakeRect(15, 460, 660, 2))
        sep.setBoxType_(AppKit.NSBoxSeparator)
        v.addSubview_(sep)
        self.knobs_editor = ActionEditorPanel(v, Foundation.NSMakeRect(15, 10, 660, 440), self._owner)

    def populate_ui(self) -> None:
        if not self.model:
            return
        app_cfg = self.model.get("app", {})
        self.cb_launch_at_login.setState_(
            AppKit.NSControlStateValueOn if app_cfg.get("launch_at_login") else AppKit.NSControlStateValueOff
        )
        self.cb_statusbar.setState_(
            AppKit.NSControlStateValueOn if app_cfg.get("statusbar", True) else AppKit.NSControlStateValueOff
        )
        lvl = app_cfg.get("log_level", "INFO")
        if lvl in ["DEBUG", "INFO", "WARNING", "ERROR"]:
            self.popup_log_level.selectItemWithTitle_(lvl)

        dev_cfg = self.model.get("device", {})
        vid = dev_cfg.get("vendor_id")
        self.tf_vendor_id.setStringValue_(f"0x{vid:04x}" if isinstance(vid, int) else str(vid or ""))
        pid = dev_cfg.get("product_id")
        self.tf_product_id.setStringValue_(f"0x{pid:04x}" if isinstance(pid, int) else str(pid or ""))

        up = dev_cfg.get("usage_page")
        self.tf_usage_page.setStringValue_(f"0x{up:04x}" if isinstance(up, int) else (str(up) if up is not None else ""))
        u = dev_cfg.get("usage")
        self.tf_usage.setStringValue_(f"0x{u:04x}" if isinstance(u, int) else (str(u) if u is not None else ""))

        proto = dev_cfg.get("protocol", "vendor")
        if proto in ["vendor", "keyboard"]:
            self.popup_protocol.selectItemWithTitle_(proto)

        lay_cfg = self.model.get("layout", {})
        self.tf_rows.setStringValue_(str(lay_cfg.get("rows", 3)))
        self.tf_cols.setStringValue_(str(lay_cfg.get("cols", 3)))
        self.tf_knobs.setStringValue_(str(lay_cfg.get("knobs", 0)))

        self.populate_keys_tab()
        self.populate_knobs_tab()

    def populate_keys_tab(self) -> None:
        for btn in self._key_buttons.values():
            btn.removeFromSuperview()
        self._key_buttons.clear()

        rows = self.model["layout"]["rows"]
        cols = self.model["layout"]["cols"]
        btn_w, btn_h = 120, 48
        gap_x, gap_y = 8, 8

        content_w = max(640, cols * (btn_w + gap_x) + gap_x)
        content_h = max(260, rows * (btn_h + gap_y) + gap_y)
        self.grid_container.setFrame_(Foundation.NSMakeRect(0, 0, content_w, content_h))

        for r in range(rows):
            for c in range(cols):
                n = r * cols + c + 1
                act = self.get_key_action(r, c)
                summary = act.get("type", "—") if act else "—"
                title = f"Key {n}\n{summary}"

                x = gap_x + c * (btn_w + gap_x)
                y = content_h - (r + 1) * (btn_h + gap_y)

                btn = AppKit.NSButton.alloc().initWithFrame_(Foundation.NSMakeRect(x, y, btn_w, btn_h))
                btn.setButtonType_(AppKit.NSButtonTypeMomentaryPushIn)
                # The default rounded bezel is single-line only; a square
                # bezel lets the two-line "Key N / action" title render.
                btn.setBezelStyle_(AppKit.NSBezelStyleRegularSquare)
                btn.setFont_(AppKit.NSFont.systemFontOfSize_(11.0))
                btn.cell().setLineBreakMode_(AppKit.NSLineBreakByWordWrapping)
                btn.setTitle_(title)
                btn.setTarget_(self._owner)
                btn.setAction_("keyButtonClicked:")
                # PyObjC proxies don't take arbitrary attributes; encode the
                # cell in the AppKit tag instead.
                btn.setTag_(r * cols + c)

                self.grid_container.addSubview_(btn)
                self._key_buttons[(r, c)] = btn

        if rows > 0 and cols > 0:
            self._selected_key = (0, 0)
            self._highlight_selected_key()
            act = self.get_key_action(0, 0)
            self.keys_editor.load_action(act)
        else:
            self._selected_key = None
            self.keys_editor.load_action(None)

    def _highlight_selected_key(self) -> None:
        for (r, c), btn in self._key_buttons.items():
            btn.setState_(AppKit.NSControlStateValueOn if (r, c) == self._selected_key else AppKit.NSControlStateValueOff)

    def populate_knobs_tab(self) -> None:
        self.popup_knob_index.removeAllItems()
        knobs_count = self.model["layout"]["knobs"]
        if knobs_count > 0:
            self.popup_knob_index.addItemsWithTitles_([f"Knob {i}" for i in range(knobs_count)])
            self.popup_knob_index.setEnabled_(True)
            self.popup_knob_index.selectItemAtIndex_(0)
            self.popup_knob_event.selectItemAtIndex_(0)
            self._selected_knob_index = 0
            self._selected_knob_event = "on_cw"
            act = self.get_knob_action(0, "on_cw")
            self.knobs_editor.load_action(act)
        else:
            self.popup_knob_index.addItemWithTitle_("None")
            self.popup_knob_index.setEnabled_(False)
            self._selected_knob_index = None
            self._selected_knob_event = None
            self.knobs_editor.load_action(None)

    def on_action_type_changed(self, sender: Any) -> None:
        if sender == self.keys_editor.action_popup:
            self.keys_editor.update_visible_type()
        elif sender == self.knobs_editor.action_popup:
            self.knobs_editor.update_visible_type()

    def on_key_button_clicked(self, sender: Any) -> None:
        r_new, c_new = divmod(sender.tag(), self.model["layout"]["cols"])
        if (r_new, c_new) == self._selected_key:
            return

        if self._selected_key is not None:
            r_old, c_old = self._selected_key
            try:
                act = self.keys_editor.collect()
                self.set_key_action(r_old, c_old, act)
                n = r_old * self.model["layout"]["cols"] + c_old + 1
                summary = act.get("type", "—") if act else "—"
                if (r_old, c_old) in self._key_buttons:
                    self._key_buttons[(r_old, c_old)].setTitle_(f"Key {n}\n{summary}")
            except ValueError as e:
                show_alert(str(e))
                self._highlight_selected_key()
                return

        self._selected_key = (r_new, c_new)
        self._highlight_selected_key()
        act = self.get_key_action(r_new, c_new)
        self.keys_editor.load_action(act)

    def on_knob_selection_changed(self, sender: Any) -> None:
        new_idx = self.popup_knob_index.indexOfSelectedItem() if self.model["layout"]["knobs"] > 0 else 0
        evt_title = self.popup_knob_event.titleOfSelectedItem()
        evt_map = {"Rotate CW": "on_cw", "Rotate CCW": "on_ccw", "Press": "on_press"}
        new_evt = evt_map.get(evt_title, "on_cw")

        if (new_idx, new_evt) == (self._selected_knob_index, self._selected_knob_event):
            return

        if self._selected_knob_index is not None and self._selected_knob_event is not None:
            old_idx = self._selected_knob_index
            old_evt = self._selected_knob_event
            try:
                act = self.knobs_editor.collect()
                self.set_knob_action(old_idx, old_evt, act)
            except ValueError as e:
                show_alert(str(e))
                self.popup_knob_index.selectItemAtIndex_(old_idx)
                rev_map = {"on_cw": "Rotate CW", "on_ccw": "Rotate CCW", "on_press": "Press"}
                self.popup_knob_event.selectItemWithTitle_(rev_map.get(old_evt, "Rotate CW"))
                return

        self._selected_knob_index = new_idx
        self._selected_knob_event = new_evt
        act = self.get_knob_action(new_idx, new_evt)
        self.knobs_editor.load_action(act)

    def on_save_pressed(self) -> None:
        if self._selected_key is not None:
            r, c = self._selected_key
            try:
                act = self.keys_editor.collect()
                self.set_key_action(r, c, act)
            except ValueError as e:
                show_alert(str(e))
                return

        if self._selected_knob_index is not None and self._selected_knob_event is not None:
            try:
                act = self.knobs_editor.collect()
                self.set_knob_action(self._selected_knob_index, self._selected_knob_event, act)
            except ValueError as e:
                show_alert(str(e))
                return

        try:
            launch_at_login = self.cb_launch_at_login.state() == AppKit.NSControlStateValueOn
            statusbar = self.cb_statusbar.state() == AppKit.NSControlStateValueOn
            log_level = self.popup_log_level.titleOfSelectedItem()

            vendor_id = parse_hex_or_int(self.tf_vendor_id.stringValue(), "Vendor ID")
            product_id = parse_hex_or_int(self.tf_product_id.stringValue(), "Product ID")
            usage_page = parse_hex_or_int(self.tf_usage_page.stringValue(), "Usage page", allow_none=True)
            usage = parse_hex_or_int(self.tf_usage.stringValue(), "Usage", allow_none=True)
            protocol = self.popup_protocol.titleOfSelectedItem()

            rows = parse_pos_int(self.tf_rows.stringValue(), "Rows")
            cols = parse_pos_int(self.tf_cols.stringValue(), "Cols")
            knobs_count = parse_nonneg_int(self.tf_knobs.stringValue(), "Knobs")
        except ValueError as e:
            show_alert(str(e))
            return

        data = {
            "device": {
                "vendor_id": vendor_id,
                "product_id": product_id,
                "usage_page": usage_page,
                "usage": usage,
                "protocol": protocol,
            },
            "layout": {"rows": rows, "cols": cols, "knobs": knobs_count},
            "app": {
                "statusbar": statusbar,
                "log_level": log_level,
                "icon": self.model.get("app", {}).get("icon"),
                "launch_at_login": launch_at_login,
            },
            "keys": [
                {"row": k["row"], "col": k["col"], "action": k["action"]}
                for k in self.model.get("keys", [])
                if k["row"] < rows and k["col"] < cols and k.get("action") is not None
            ],
            "knobs": [
                {
                    "index": kn["index"],
                    "on_cw": kn.get("on_cw"),
                    "on_ccw": kn.get("on_ccw"),
                    "on_press": kn.get("on_press"),
                }
                for kn in self.model.get("knobs", [])
                if kn["index"] < knobs_count and any(kn.get(e) for e in ("on_cw", "on_ccw", "on_press"))
            ],
        }

        tmp_path = None
        try:
            toml_text = tomlio.dumps_toml(data)
            tmp_fd, tmp_path = tempfile.mkstemp(prefix="keypad_cfg_", suffix=".toml")
            with os.fdopen(tmp_fd, "w", encoding="utf-8") as f:
                f.write(toml_text)

            config.load_config(tmp_path)
            os.replace(tmp_path, self.config_path)
            tmp_path = None
        except (config.ConfigError, ValueError, Exception) as e:
            if tmp_path and os.path.exists(tmp_path):
                try:
                    os.unlink(tmp_path)
                except Exception:
                    pass
            show_alert(str(e))
            return

        try:
            loginitem.set_enabled(launch_at_login)
        except Exception as e:
            logger.warning("Failed to update launch at login item: %s", e)

        if self.on_saved:
            try:
                self.on_saved()
            except Exception as e:
                logger.error("Error in on_saved callback: %s", e)

        self.reload_from_disk()

    def on_revert_pressed(self) -> None:
        self.reload_from_disk()
