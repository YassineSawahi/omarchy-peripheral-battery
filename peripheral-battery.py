#!/usr/bin/env python3
"""Read battery state from Redragon's Compx-based 2.4G receivers over hidraw.

Prints one JSON object on stdout for BarWidget.qml. Stdlib only.

Mouse (K1NG M916, receiver 3554:f54f) speaks the Compx protocol on the
vendor interface's report 0x08: a 16-byte payload whose last byte makes the
whole packet (report ID included) sum to 0x55. Command 0x04 answers with
battery percent, charge state (0 discharging, 1 charging, 2 full) and the
cell voltage in mV; command 0x12 answers with the firmware version.

Keyboard (K681 PRO, receiver 3554:fa09) speaks the BYCOMBO/"3632" protocol
on report 0x13: [0x13, cmd, total, seq, len, 14 data bytes, sum-checksum].
Reads are 0x40|cmd. Neither Redragon's driver nor the firmware expose a
battery read over 2.4G, so only the link state (cmd 0x07) is reported.

Access needs the udev rule in /etc/udev/rules.d/70-redragon-hidraw.rules.
"""

import glob
import json
import os
import select
import sys
import time

VENDOR = 0x3554

# (pid, marker) — the marker picks the vendor interface out of the several
# hidraw nodes each receiver exposes: usage page 0xff02, collection, report ID.
MOUSE = (0xF54F, bytes.fromhex("0602ff0902a1018508"))
KEYBOARD = (0xFA09, bytes.fromhex("0602ff0902a1018513"))

CHARGE_STATES = {0: "discharging", 1: "charging", 2: "full"}


def find_hidraw(pid, marker):
    want = f"HID_ID=0003:{VENDOR:08X}:{pid:08X}"
    for node in sorted(glob.glob("/sys/class/hidraw/hidraw*")):
        try:
            with open(os.path.join(node, "device/uevent")) as f:
                if want not in f.read():
                    continue
            with open(os.path.join(node, "device/report_descriptor"), "rb") as f:
                if marker in f.read():
                    return "/dev/" + os.path.basename(node)
        except OSError:
            continue
    return None


def open_dev(path):
    """Returns an fd, or an error string the widget can show."""
    if path is None:
        return "absent"
    try:
        return os.open(path, os.O_RDWR | os.O_NONBLOCK)
    except PermissionError:
        return "no-access"
    except OSError:
        return "absent"


def drain(fd):
    while select.select([fd], [], [], 0)[0]:
        os.read(fd, 64)


def transact(fd, packet, match, wait, tries):
    """Writes packet and returns the first input report match() accepts.

    Retries because a sleeping device misses the first query or two.
    """
    for _ in range(tries):
        drain(fd)
        os.write(fd, packet)
        end = time.monotonic() + wait
        while time.monotonic() < end:
            if select.select([fd], [], [], 0.05)[0]:
                report = os.read(fd, 64)
                if match(report):
                    return report
    return None


def compx_packet(cmd):
    body = bytearray(16)
    body[0] = cmd
    body[15] = (0x55 - 0x08 - sum(body[:15])) & 0xFF
    return bytes([0x08]) + bytes(body)


def read_mouse():
    out = {"id": "mouse", "name": "K1NG M916", "kind": "mouse"}
    fd = open_dev(find_hidraw(*MOUSE))
    if isinstance(fd, str):
        return {**out, "status": fd}
    try:
        def is_reply(cmd):
            return lambda r: len(r) >= 10 and r[0] == 0x08 and r[1] == cmd

        # An idle mouse takes most of a second to answer the first query.
        battery = transact(fd, compx_packet(0x04), is_reply(0x04), wait=1.5, tries=3)
        if battery is None or battery[6] > 100:
            return {**out, "status": "asleep"}
        out.update(status="ok", level=battery[6],
                   state=CHARGE_STATES.get(battery[7], "unknown"))
        millivolts = (battery[8] << 8) | battery[9]
        if 3000 <= millivolts <= 4500:
            out["voltage"] = round(millivolts / 1000, 3)

        firmware = transact(fd, compx_packet(0x12), is_reply(0x12), wait=0.3, tries=1)
        if firmware is not None:
            out["firmware"] = f"{firmware[6]:x}.{firmware[7]:02x}"
        return out
    finally:
        os.close(fd)


def bycombo_packet(cmd):
    packet = bytearray(20)
    packet[0], packet[1], packet[2] = 0x13, cmd, 0x01
    packet[19] = sum(packet[:19]) & 0xFF
    return bytes(packet)


def read_keyboard():
    out = {"id": "keyboard", "name": "K681 PRO", "kind": "keyboard"}
    fd = open_dev(find_hidraw(*KEYBOARD))
    if isinstance(fd, str):
        return {**out, "status": fd}
    try:
        link = transact(fd, bycombo_packet(0x07),
                        lambda r: len(r) >= 6 and r[0] == 0x13 and r[1] == 0x07,
                        wait=0.5, tries=2)
        if link is None or link[5] != 1:
            return {**out, "status": "asleep"}
        return {**out, "status": "ok", "level": None}
    finally:
        os.close(fd)


CACHE = os.path.join(os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
                     "omarchy", "peripheral-battery.json")


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def save_cache(cache):
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    tmp = CACHE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cache, f)
    os.replace(tmp, CACHE)


def main():
    now = int(time.time())
    cache = load_cache()
    devices = []
    for reader in (read_mouse, read_keyboard):
        try:
            device = reader()
        except OSError as e:
            device = {"id": reader.__name__[5:], "status": "error", "error": str(e)}
        # A sleeping device can't be reached over RF, so fall back to its
        # last good reading (flagged stale) rather than showing nothing.
        if device["status"] == "ok":
            device["seenAt"] = now
            cache[device["id"]] = device
        elif device["status"] == "asleep" and device["id"] in cache:
            device = {**cache[device["id"]], "status": "asleep", "stale": True}
        devices.append(device)
    try:
        save_cache(cache)
    except OSError:
        pass
    json.dump({"devices": devices, "time": now}, sys.stdout)
    print()


if __name__ == "__main__":
    main()
