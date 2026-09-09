## Resolving Immediate Bluetooth Disconnects on Fedora 42

This issue is a known behavior on Fedora 42, usually caused by a handshake conflict between BlueZ, your audio router (WirePlumber/PipeWire), and specific Bluetooth hardware features. When you connect, the system creates an initial connection but drops it immediately when negotiating the audio profile (A2DP/HSP).
Here are the most effective fixes, ordered from the simplest to the most advanced.

### 1. Disable the "FastConnectable" Feature (Most Common Fix)

A mismatch between Linux's modern Bluetooth stack and certain hardware controllers (like MediaTek or Intel) often triggers instant disconnects. Disabling `FastConnectable` solves this.

Open your terminal and edit your primary Bluetooth configuration file:

```bash
sudo nano /etc/bluetooth/main.conf
```

Use `Ctrl + W` to search for the following line:

```ini
#FastConnectable = false

```

Remove the `#` symbol to uncomment it, and make sure it is explicitly set to false:

```ini
FastConnectable = false

```

Save and exit (`Ctrl + O`, `Enter`, then `Ctrl + X`), then restart the Bluetooth service:

```bash
sudo systemctl restart bluetooth

```

### 2. Turn Off WirePlumber Audio Profile Autoswitching

A bug in recent WirePlumber packages can crash or drop connections the moment an earbud tries to cycle through high-fidelity (A2DP) and headset (HSP/HFP) profiles simultaneously.

Run this command in the terminal to prevent the auto-switch loop:

```bash
wpctl settings --save bluetooth.autoswitch-to-headset-profile false

```

> **Note:** If you need to revert this later, change `false` to `true`.

### 3. Clear the BlueZ Cache and Force Re-Pairing

Sometimes corrupted state data cached in your local system cache causes persistent drops. Clearing it forces Fedora to create a fresh handshake:

```bash
sudo systemctl stop bluetooth
sudo rm -rf /var/lib/bluetooth/*
sudo systemctl start bluetooth

```

After running this, put your TWS earbuds back into manual pairing mode, open your Bluetooth menu, and connect to them again as a brand-new device.

### 4. Check for Dual-Connection Interference (Multi-pairing)

Many modern TWS earbuds support dual-point connectivity or aggressively seek their last paired device (like your phone). If the earbuds connect to Fedora but then instantly detect your phone's Bluetooth, they may drop the Linux connection to favor the mobile device.

**The Fix:** Temporarily disable Bluetooth on your phone and any other nearby devices, then test the connection to your Fedora machine.

---

### Still experiencing issues?

If none of these resolve the issue, please provide the following details to help troubleshoot further:

* The desktop environment you are running (e.g., GNOME or KDE Plasma)
* The make and model of your TWS earbuds
* The terminal output of running `journalctl -b 0 | grep -i bluetooth` immediately after a disconnect happens