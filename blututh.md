**From a normal shell, not the bluetoothctl prompt**

```
bluetoothctl trust 41:42:A4:46:3F:A2
bluetoothctl scan off
bluetoothctl connect 41:42:A4:46:3F:A2
```

**Connect**

```
bluetoothctl scan off
bluetoothctl connect 41:42:A4:46:3F:A2
```

**Verify state**

```
bluetoothctl info 41:42:A4:46:3F:A2
wpctl status | grep -A5 Sinks
```

**Watch it drop (two terminals)**

```
journalctl -u bluetooth -f
```

```
btmon
```

**Fix the hostname / adapter alias**

```
hostnamectl hostname fedora-laptop
sudo systemctl restart bluetooth
bluetoothctl show | grep Alias
```

**Disable btusb autosuspend (persistent)**

```
echo "options btusb enable_autosuspend=0" | sudo tee /etc/modprobe.d/btusb.conf
sudo dracut -f
sudo reboot
```

**Force A2DP if it lands on HFP**

```
pactl list cards short
pactl set-card-profile bluez_card.41_42_A4_46_3F_A2 a2dp-sink
```







```sh
# From a normal shell, not the bluetoothctl prompt
bluetoothctl trust 41:42:A4:46:3F:A2
bluetoothctl scan off
bluetoothctl connect 41:42:A4:46:3F:A2

# Connect
bluetoothctl scan off
bluetoothctl connect 41:42:A4:46:3F:A2

# Verify state
bluetoothctl info 41:42:A4:46:3F:A2
wpctl status | grep -A5 Sinks

# Watch it drop (two terminals)
journalctl -u bluetooth -f
btmon

# Fix the hostname / adapter alias
hostnamectl hostname fedora-laptop
sudo systemctl restart bluetooth
bluetoothctl show | grep Alias

# Disable btusb autosuspend (persistent)
echo "options btusb enable_autosuspend=0" | sudo tee /etc/modprobe.d/btusb.conf
sudo dracut -f
sudo reboot

# Force A2DP if it lands on HFP
pactl list cards short
pactl set-card-profile bluez_card.41_42_A4_46_3F_A2 a2dp-sink
```