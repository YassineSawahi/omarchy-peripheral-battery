# Peripheral battery for Omarchy

An [Omarchy](https://omarchy.org) bar widget that shows the battery of a **Redragon K1NG M916** mouse and the link state of a **Redragon K681 PRO** keyboard, read straight from their 2.4G receivers over hidraw. Nothing runs in the background and nothing goes over the network. It's one small stdlib Python script.

## What it shows

- **Bar:** a mouse icon with its battery percentage, a bolt while charging, and red at or below your low threshold.
- **Popup** (left click): each device with its level, charge state, cell voltage and firmware.
- **Low battery:** a notification once per discharge (critical at 10%).
- **Asleep:** the mouse can't be reached over RF while it naps, so the last good reading stays up, dimmed, with the time it was taken.

The K681 PRO doesn't report its battery over 2.4G (Redragon's own Windows driver doesn't read it either), so the widget only shows that the keyboard is connected. Hold **Fn+Alt** on the keyboard to see its level on the number row.

## Install

```bash
omarchy plugin add https://github.com/YassineSawahi/omarchy-peripheral-battery.git --enable
```

Then let your user open the receivers (once, needs root):

```bash
sudo cp ~/.config/omarchy/plugins/io.github.yassinesawahi.peripheral-battery/udev/70-redragon-hidraw.rules /etc/udev/rules.d/
sudo udevadm control --reload && sudo udevadm trigger
```

Unplug and replug the receivers if the widget still says "No access to the receiver".

## Controls

| Action | Does |
|---|---|
| Left click | Open or close the popup |
| Right or middle click | Read the devices again |
| `omarchy-shell io.github.yassinesawahi.peripheral-battery toggle` | Open or close the popup (bind it to a key) |
| `… refresh` / `… close` | Read again / close the popup |

Settings (in Omarchy's widget settings): refresh interval (default 120 s) and low battery threshold (default 20%).

## How it works

Everything happens on this PC, between the widget and the USB receivers. Nothing runs in the background and nothing goes over the network.

Each refresh, the widget runs `peripheral-battery.py`, which:

1. finds each receiver among the `/dev/hidraw*` nodes (USB vendor `3554`), and picks its vendor interface out by the report descriptor,
2. writes one small query packet to it, and waits for the answer the receiver brings back from the mouse or keyboard over 2.4G,
3. prints one JSON object for the widget.

A mouse that's asleep doesn't answer, so the last good reading is kept in `~/.cache/omarchy/peripheral-battery.json` and shown dimmed until a fresh one comes in. The low battery warning is an ordinary desktop notification from the widget.

Hidraw nodes belong to root. The udev rule tags Redragon's receivers `uaccess`, which lets whoever is logged in at the desk open them, so the script never needs `sudo`.

## Other Redragon devices

Both receivers are Compx-based (USB vendor `3554`). The protocol notes are at the top of [`peripheral-battery.py`](peripheral-battery.py). Other Compx mice may answer the same battery command (`0x04` on report `0x08`) under a different product ID. Change `MOUSE` in the script to try yours.

## Remove

```bash
omarchy plugin remove io.github.yassinesawahi.peripheral-battery
sudo rm /etc/udev/rules.d/70-redragon-hidraw.rules && sudo udevadm control --reload
rm -f ~/.cache/omarchy/peripheral-battery.json    # the last reading
```

## License

MIT
