#!/usr/bin/env bash
# Installs Whisper dictation for KDE Plasma 6 (Wayland) on Bazzite / Fedora Atomic.
# Run from anywhere: ./client/kde/install-kde.sh
#   Meta+Alt+D        -> dictate English
#   Meta+Alt+Shift+D  -> dictate Romanian
# (Meta+D is taken by "Peek at Desktop" in Plasma 6.)
#
# Prerequisites (layered or in your image): ydotool wl-clipboard jq curl pipewire-utils
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Script
install -Dm755 dictate.sh ~/.local/bin/dictate.sh

# 2. uinput permissions (system-level, needs sudo once)
sudo install -m644 kde/80-uinput.rules /etc/udev/rules.d/80-uinput.rules
# On Fedora Atomic the input group lives in /usr/lib/group; copy it to /etc/group first
grep -q '^input:' /etc/group || grep '^input:' /usr/lib/group | sudo tee -a /etc/group >/dev/null
sudo usermod -aG input "$USER"
sudo udevadm control --reload-rules && sudo udevadm trigger --name-match=uinput

# 3. ydotool daemon as a user service
install -Dm644 kde/ydotoold.service ~/.config/systemd/user/ydotoold.service
systemctl --user daemon-reload
systemctl --user enable ydotoold.service

# The client needs to find the socket
mkdir -p ~/.config/environment.d
echo 'YDOTOOL_SOCKET=${XDG_RUNTIME_DIR}/.ydotool_socket' > ~/.config/environment.d/ydotool.conf

# 4. Launchers + global shortcuts
# (.desktop Exec= doesn't expand ~ or $HOME, so substitute the real path)
mkdir -p ~/.local/share/applications
for lang in en ro; do
  sed "s|@HOME@|$HOME|" "kde/dictate-$lang.desktop" > ~/.local/share/applications/dictate-$lang.desktop
done

kwriteconfig6 --file kglobalshortcutsrc --group services --group dictate-en.desktop \
  --key _launch "Meta+Alt+D"
kwriteconfig6 --file kglobalshortcutsrc --group services --group dictate-ro.desktop \
  --key _launch "Meta+Alt+Shift+D"

echo
echo "Done. Log out and back in (needed for the input group, env var and shortcuts)."
echo "Shortcuts can be changed in System Settings > Keyboard > Shortcuts."
