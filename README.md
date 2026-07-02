# Tidal Hi-Fi Memory Watchdog

> A lightweight watchdog and wrapper script for the Tidal Hi-Fi Flatpak. It preemptively restarts the app before its baked-in memory leak can cause a crash, using desktop notifications to warn you beforehand.

**For use with:**
`flatpak run com.mastermindzh.tidal-hifi`

## Installation Options

You can run this project in two ways:

1. **As a background service:** Runs invisibly in the background at all times using `systemd`.
2. **As a standalone wrapper script (`runtidal.sh`):** A script you use to launch Tidal, which acts as the watchdog only while the script is actively running.

---

### Option A: Systemd Background Service (Recommended)

This method utilizes `tidal-hifi-watchdog.service` to keep the watchdog running in the background automatically.

**1. Create necessary directories**

```bash
mkdir -p ~/.local/bin ~/.config/systemd/user

```

**2. Install the watchdog script**

```bash
cp tidal-hifi-watchdog.sh ~/.local/bin/
chmod +x ~/.local/bin/tidal-hifi-watchdog.sh

```

**3. Install and enable the systemd service**

```bash
cp tidal-hifi-watchdog.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now tidal-hifi-watchdog.service

```

**4. Check the logs to ensure it is running**

```bash
journalctl --user -u tidal-hifi-watchdog -f

```

---

### Option B: Standalone Launcher (`runtidal.sh`)

If you prefer not to use a background service, you can use `runtidal.sh` to launch Tidal. It will immediately open the app and monitor it until you close the terminal or kill the script.

**1. Make the launcher executable**

```bash
chmod +x runtidal.sh

```

**2. Run it**

```bash
./runtidal.sh

```

---

## Highly Recommended: Disable Core Dumps

Because the Electron app leaks memory, when it eventually crashes or is killed by the watchdog, your system may attempt to write a massive core dump to your disk. This causes severe disk I/O spikes and system stuttering. Disable it specifically for these instances:

```bash
sudo mkdir -p /etc/systemd/coredump.conf.d
sudo tee /etc/systemd/coredump.conf.d/cheap.conf >/dev/null <<'EOF'
[Coredump]
Storage=none
ProcessSizeMax=0
EOF

```

---

## Desktop Integration (For Option B Users)

If you are using `runtidal.sh` as a standalone launcher, you can integrate it into your application menu by creating a `.desktop` shortcut.

**1. Create a file named `tidal-watchdog.desktop` in `~/.local/share/applications/`:**

```bash
nano ~/.local/share/applications/tidal-watchdog.desktop

```

**2. Paste the following configuration:**
*(Ensure you replace `YOUR_USERNAME` with your actual Linux username)*

```ini
[Desktop Entry]
Name=Tidal Hi-Fi (Watchdog)
Comment=Launches Tidal with a memory-leak watchdog
Exec=/home/YOUR_USERNAME/.local/bin/runtidal.sh
Icon=com.mastermindzh.tidal-hifi
Terminal=false
Type=Application
Categories=AudioVideo;Audio;Player;

```

**3. Update your application database (optional, usually automatic):**

```bash
update-desktop-database ~/.local/share/applications/

```

## Configuration Options

If you are using the systemd service (`tidal-hifi-watchdog.service`), you can adjust tunables such as `MEM_LIMIT_MB` or `WARN_SECONDS` directly inside the `.service` file.

After editing the tunables, apply them by running:

```bash
systemctl --user restart tidal-hifi-watchdog

```
