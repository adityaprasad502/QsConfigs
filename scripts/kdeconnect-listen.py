#!/usr/bin/env python3
"""
KDE Connect D-Bus signal listener for Quickshell.
Outputs one JSON line on startup (initial state), then one JSON line
per event whenever battery, network, reachability, or device lists change.
Also sends desktop notifications for important phone battery/connection events.
Runs persistently — Quickshell's SplitParser reads each line as it arrives.
"""
import sys
import json
import subprocess
import dbus
import dbus.mainloop.glib
from gi.repository import GLib

dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)

KDC = "org.kde.kdeconnect"
LOW_THRESHOLD = 20   # notify when battery drops below this while discharging
FULL_THRESHOLD = 100 # notify when battery reaches this while charging

bus = None
device_receivers = {}  # dev_id -> list of signal match objects
device_states = {}     # dev_id -> { "battery": dict, "reachable": dict, "name": str }

def get_bus():
    global bus
    if bus is None:
        bus = dbus.SessionBus()
    return bus

def notify(summary, body, urgency="normal", icon="phone", app_name="Phone"):
    try:
        subprocess.Popen([
            "notify-send",
            f"--app-name={app_name}",
            f"--urgency={urgency}",
            f"--icon={icon}",
            summary,
            body
        ], close_fds=True)
    except Exception:
        pass

def get_prop(path, iface, prop):
    try:
        b = get_bus()
        obj = b.get_object(KDC, path)
        props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
        return props.Get(iface, prop)
    except Exception:
        return None

def emit(data):
    print(json.dumps(data), flush=True)

def get_paired_devices():
    b = get_bus()
    result = []

    # Method 1: Daemon interface devices(False, True) -> (onlyReachable=False, onlyPaired=True)
    try:
        mgr = b.get_object(KDC, "/modules/kdeconnect")
        daemon = dbus.Interface(mgr, "org.kde.kdeconnect.daemon")
        dev_ids = daemon.devices(False, True)
        for dev_id in dev_ids:
            dev_id = str(dev_id)
            path = f"/modules/kdeconnect/devices/{dev_id}"
            try:
                obj = b.get_object(KDC, path)
                props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
                name = props.Get("org.kde.kdeconnect.device", "name")
                result.append((dev_id, str(name)))
            except Exception:
                result.append((dev_id, dev_id))
        if result:
            return result
    except Exception:
        pass

    # Method 2: Introspect /modules/kdeconnect/devices
    try:
        import xml.etree.ElementTree as ET
        mgr = b.get_object(KDC, "/modules/kdeconnect/devices")
        iface = dbus.Interface(mgr, "org.freedesktop.DBus.Introspectable")
        xml_data = iface.Introspect()
        root = ET.fromstring(xml_data)
        for node in root.findall("node"):
            dev_id = node.get("name")
            if not dev_id:
                continue
            path = f"/modules/kdeconnect/devices/{dev_id}"
            try:
                obj = b.get_object(KDC, path)
                props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
                if not props.Get("org.kde.kdeconnect.device", "isPaired"):
                    continue
                name = props.Get("org.kde.kdeconnect.device", "name")
                result.append((str(dev_id), str(name)))
            except Exception:
                pass
        return result
    except Exception:
        return []

def cleanup_device(dev_id):
    if dev_id in device_receivers:
        for receiver in device_receivers[dev_id]:
            try:
                receiver.remove()
            except Exception:
                pass
        del device_receivers[dev_id]
    device_states.pop(dev_id, None)

def make_battery_handler(dev_id, state, reachable_state):
    def handler(is_charging, charge, **kw):
        charge = int(charge)
        is_charging = bool(is_charging)
        prev_charging = state.get("charging")
        name = reachable_state.get("name", "Phone")

        emit({"event": "battery", "id": dev_id, "charge": charge, "charging": is_charging})

        # Charging plugged in / unplugged
        if prev_charging is not None and prev_charging != is_charging:
            if is_charging:
                notify(f"{name} is charging", f"Battery at {charge}%", urgency="low", icon="battery-caution-charging", app_name=name)
                state["low_notified"]  = False
                state["full_notified"] = (charge >= FULL_THRESHOLD)
            else:
                notify(f"{name} was unplugged", f"Battery at {charge}%", urgency="low", icon="battery-good", app_name=name)
                state["low_notified"]  = (0 < charge < LOW_THRESHOLD)
                state["full_notified"] = False

        # Battery full
        if is_charging and charge >= FULL_THRESHOLD and not state.get("full_notified"):
            notify(f"{name} is fully charged", f"Battery is at {charge}% — safe to unplug", urgency="normal", icon="battery-full-charged", app_name=name)
            state["full_notified"] = True
            state["low_notified"]  = False

        # Battery low (only while discharging, and charge > 0 to avoid -1% invalid reports)
        if not is_charging and 0 < charge < LOW_THRESHOLD and not state.get("low_notified"):
            notify(f"{name} battery is low", f"Battery at {charge}% — please charge", urgency="critical", icon="battery-caution", app_name=name)
            state["low_notified"]  = True
            state["full_notified"] = False

        # Reset full_notified if battery drops meaningfully after unplugging
        if not is_charging and 0 < charge < (FULL_THRESHOLD - 5):
            state["full_notified"] = False

        state["charge"]   = charge
        state["charging"] = is_charging

    return handler

def make_network_handler(dev_id):
    def handler(net_type, strength, **kw):
        emit({"event": "network", "id": dev_id, "netType": str(net_type), "netStrength": int(strength)})
    return handler

def make_reachable_handler(dev_id, reachable_state):
    def handle(reachable, **kw):
        reachable = bool(reachable)
        prev = reachable_state.get("reachable")
        reachable_state["reachable"] = reachable
        if prev == reachable:
            return  # no change, skip duplicate notifications
        name = reachable_state.get("name", "Phone")
        emit({"event": "reachable", "id": dev_id, "name": name, "reachable": reachable})
        if reachable:
            notify(f"{name} is connected", "Phone is now reachable", urgency="low", icon="phone", app_name=name)
        else:
            notify(f"{name} is disconnected", "Phone is out of range", urgency="low", icon="phone-missed", app_name=name)
    return handle

def make_name_handler(dev_id, reachable_state):
    def handle(new_name, **kw):
        new_name = str(new_name)
        reachable_state["name"] = new_name
        emit({"event": "name", "id": dev_id, "name": new_name})
    return handle

def make_properties_changed_handler(dev_id, reachable_state):
    reachable_handler = make_reachable_handler(dev_id, reachable_state)
    def handle(interface, changed, invalidated, **kw):
        if "isReachable" in changed:
            reachable_handler(bool(changed["isReachable"]))
        if "name" in changed:
            new_name = str(changed["name"])
            reachable_state["name"] = new_name
            emit({"event": "name", "id": dev_id, "name": new_name})
    return handle

def setup_device(dev_id, name=None):
    if dev_id in device_receivers:
        return

    b = get_bus()
    path = f"/modules/kdeconnect/devices/{dev_id}"

    # Verify pairing
    is_paired = get_prop(path, "org.kde.kdeconnect.device", "isPaired")
    if is_paired is not None and not is_paired:
        return

    if not name:
        d_name = get_prop(path, "org.kde.kdeconnect.device", "name")
        name = str(d_name) if d_name else dev_id

    # Current initial states
    reachable = get_prop(path, "org.kde.kdeconnect.device", "isReachable")
    charge    = get_prop(f"{path}/battery", "org.kde.kdeconnect.device.battery", "charge")
    charging  = get_prop(f"{path}/battery", "org.kde.kdeconnect.device.battery", "isCharging")
    net_type  = get_prop(f"{path}/connectivity_report", "org.kde.kdeconnect.device.connectivity_report", "cellularNetworkType")
    net_str   = get_prop(f"{path}/connectivity_report", "org.kde.kdeconnect.device.connectivity_report", "cellularNetworkStrength")

    init_reachable = bool(reachable) if reachable is not None else False
    init_charging  = bool(charging) if charging is not None else False
    init_charge    = int(charge) if charge is not None else -1

    emit({
        "event":       "state",
        "id":          dev_id,
        "name":        name,
        "reachable":   init_reachable,
        "charge":      init_charge,
        "charging":    init_charging,
        "netType":     str(net_type) if net_type is not None else "",
        "netStrength": int(net_str)  if net_str  is not None else 0,
    })

    battery_state = {
        "low_notified": (0 < init_charge < LOW_THRESHOLD and not init_charging),
        "full_notified": (init_charge >= FULL_THRESHOLD and init_charging),
        "charging": init_charging if charge is not None else None,
        "charge": init_charge
    }
    reachable_state = {
        "reachable": init_reachable,
        "name": name
    }
    device_states[dev_id] = {
        "battery": battery_state,
        "reachable": reachable_state,
        "name": name
    }

    receivers = []
    try:
        r_bat = b.add_signal_receiver(
            make_battery_handler(dev_id, battery_state, reachable_state),
            signal_name="refreshed",
            dbus_interface="org.kde.kdeconnect.device.battery",
            path=f"{path}/battery"
        )
        receivers.append(r_bat)

        r_net = b.add_signal_receiver(
            make_network_handler(dev_id),
            signal_name="refreshed",
            dbus_interface="org.kde.kdeconnect.device.connectivity_report",
            path=f"{path}/connectivity_report"
        )
        receivers.append(r_net)

        r_reach = b.add_signal_receiver(
            make_reachable_handler(dev_id, reachable_state),
            signal_name="reachableChanged",
            dbus_interface="org.kde.kdeconnect.device",
            path=path
        )
        receivers.append(r_reach)

        r_name = b.add_signal_receiver(
            make_name_handler(dev_id, reachable_state),
            signal_name="nameChanged",
            dbus_interface="org.kde.kdeconnect.device",
            path=path
        )
        receivers.append(r_name)

        r_prop = b.add_signal_receiver(
            make_properties_changed_handler(dev_id, reachable_state),
            signal_name="PropertiesChanged",
            dbus_interface="org.freedesktop.DBus.Properties",
            path=path
        )
        receivers.append(r_prop)
    except Exception:
        pass

    device_receivers[dev_id] = receivers

def sync_all_devices():
    found_devices = get_paired_devices()
    current_ids = set(device_receivers.keys())
    found_ids = {dev_id for dev_id, _ in found_devices}

    # Remove unlisted devices
    for dev_id in (current_ids - found_ids):
        cleanup_device(dev_id)
        emit({"event": "device_removed", "id": dev_id})

    if not found_devices:
        emit({"event": "nodevices"})
        return

    # Add or update discovered devices
    for dev_id, name in found_devices:
        if dev_id not in device_receivers:
            setup_device(dev_id, name)
        else:
            path = f"/modules/kdeconnect/devices/{dev_id}"
            reachable = get_prop(path, "org.kde.kdeconnect.device", "isReachable")
            charge    = get_prop(f"{path}/battery", "org.kde.kdeconnect.device.battery", "charge")
            charging  = get_prop(f"{path}/battery", "org.kde.kdeconnect.device.battery", "isCharging")
            net_type  = get_prop(f"{path}/connectivity_report", "org.kde.kdeconnect.device.connectivity_report", "cellularNetworkType")
            net_str   = get_prop(f"{path}/connectivity_report", "org.kde.kdeconnect.device.connectivity_report", "cellularNetworkStrength")
            emit({
                "event":       "state",
                "id":          dev_id,
                "name":        name,
                "reachable":   bool(reachable) if reachable is not None else False,
                "charge":      int(charge) if charge is not None else -1,
                "charging":    bool(charging) if charging is not None else False,
                "netType":     str(net_type) if net_type is not None else "",
                "netStrength": int(net_str) if net_str is not None else 0,
            })

def on_device_added(dev_id, **kw):
    setup_device(str(dev_id))

def on_device_removed(dev_id, **kw):
    dev_id = str(dev_id)
    cleanup_device(dev_id)
    emit({"event": "device_removed", "id": dev_id})
    if not device_receivers:
        emit({"event": "nodevices"})

def on_device_visibility_changed(dev_id, is_visible, **kw):
    dev_id = str(dev_id)
    is_visible = bool(is_visible)
    if dev_id in device_states:
        reachable_state = device_states[dev_id]["reachable"]
        prev = reachable_state.get("reachable")
        reachable_state["reachable"] = is_visible
        if prev != is_visible:
            name = reachable_state.get("name", "Phone")
            emit({"event": "reachable", "id": dev_id, "name": name, "reachable": is_visible})
            if is_visible:
                notify(f"{name} is connected", "Phone is now reachable", urgency="low", icon="phone", app_name=name)
            else:
                notify(f"{name} is disconnected", "Phone is out of range", urgency="low", icon="phone-missed", app_name=name)

def on_name_owner_changed(name, old_owner, new_owner, **kw):
    if name == KDC:
        if new_owner:
            sync_all_devices()
        else:
            for dev_id in list(device_receivers.keys()):
                cleanup_device(dev_id)
            emit({"event": "nodevices"})

def setup_daemon_listeners():
    b = get_bus()
    try:
        b.add_signal_receiver(
            on_device_added,
            signal_name="deviceAdded",
            dbus_interface="org.kde.kdeconnect.daemon",
            path="/modules/kdeconnect"
        )
        b.add_signal_receiver(
            on_device_removed,
            signal_name="deviceRemoved",
            dbus_interface="org.kde.kdeconnect.daemon",
            path="/modules/kdeconnect"
        )
        b.add_signal_receiver(
            on_device_visibility_changed,
            signal_name="deviceVisibilityChanged",
            dbus_interface="org.kde.kdeconnect.daemon",
            path="/modules/kdeconnect"
        )
    except Exception:
        pass

    try:
        b.add_signal_receiver(
            on_name_owner_changed,
            signal_name="NameOwnerChanged",
            dbus_interface="org.freedesktop.DBus",
            path="/org/freedesktop/DBus"
        )
    except Exception:
        pass

def periodic_recheck():
    # If no devices are currently connected or registered, attempt a re-scan
    if not device_receivers:
        sync_all_devices()
    return True

# --- Main ---
try:
    setup_daemon_listeners()
    sync_all_devices()
    GLib.timeout_add_seconds(30, periodic_recheck)
    GLib.MainLoop().run()
except Exception:
    sys.exit(1)
