# whisper-stt

Self-hosted speech-to-text on CPU with faster-whisper (int8), with:

- a **Home Assistant** voice backend (Wyoming protocol)
- an **OpenAI-compatible REST API** for scripts and other services
- **push-to-talk dictation** on the desktop (Hyprland and KDE Plasma), which types the transcript into whatever window has focus: a terminal prompt, an editor, a browser

English and Romanian are both supported.

```
┌───────────────────── gb-server (Docker) ──────────────────────┐
│  speaches        :8000   OpenAI REST API    medium  (en + ro) │◄── dictate.sh, curl, Open WebUI, n8n…
│  faster-whisper  :10300  Wyoming protocol   small-int8  (en)  │◄── Home Assistant
└───────────────────────────────────────────────────────────────┘
```

## Repository layout

```
.
├── server/
│   └── compose.yaml            # speaches + linuxserver/faster-whisper
└── client/
    ├── dictate.sh              # push-to-talk script (Hyprland and KDE)
    ├── hyprland/
    │   └── dictate.conf        # keybinds
    └── kde/
        ├── install-kde.sh      # one-shot installer
        ├── dictate-en.desktop  # launcher for the global shortcut
        ├── dictate-ro.desktop
        ├── ydotoold.service    # systemd user unit
        └── 80-uinput.rules     # udev rule for /dev/uinput
```

---

## 1. Server

### Requirements

- Docker with the Compose plugin (Podman with `podman compose` also works)
- About 2.5 GB of free RAM. The two services are separate processes, so each loads its own copy of
  its model into its own memory: speaches runs **medium** (about 1.5–2 GB, and it unloads when idle),
  the Wyoming server for Home Assistant runs **small-int8** (about 0.5 GB, always loaded). A shared
  volume would dedupe the models on disk but never in RAM.
- About 2 GB of disk for the models

### Start it

```bash
cd server
docker compose up -d

# Download the medium model into speaches (one time)
curl -X POST http://localhost:8000/v1/models/Systran/faster-whisper-medium
```

The `faster-whisper` container downloads its model into `server/faster-whisper/` on first start. Follow progress with `docker logs -f faster-whisper`.

### Test the REST API

```bash
# Record 5 seconds and transcribe it
pw-record --rate 16000 --channels 1 --format s16 test.wav & sleep 5; kill %1

curl http://gb-server:8000/v1/audio/transcriptions \
  -F file=@test.wav \
  -F model=Systran/faster-whisper-medium \
  -F language=en
```

- Set `language=ro` for Romanian, or leave it out to auto-detect. Auto-detection is unreliable on short clips.
- Add `-F stream=true` to receive segments over SSE as they're transcribed.
- Interactive API docs are at `http://gb-server:8000/docs`.

speaches loads a model on its first request and unloads it after a period of inactivity. Expect the first request after an idle period to be slow.

### Tuning

| Setting | Where | Notes |
|---|---|---|
| `WHISPER_MODEL` | faster-whisper env | Default `small-int8`. `medium-int8` is more accurate but costs about 1 GB more RAM; worth it if you switch this server to Romanian |
| `WHISPER_BEAM` | faster-whisper env | `1` is fastest; `3`–`5` is more accurate |
| `WHISPER_LANG` | faster-whisper env | Language for Home Assistant: `en`, `ro`, or `auto` |
| `model` request field | speaches | Any faster-whisper model ID, e.g. `Systran/faster-whisper-small` |

---

## 2. Home Assistant

1. Go to **Settings → Devices & services → Add integration → Wyoming Protocol**.
2. Set the host to `gb-server` and the port to `10300`.
3. Go to **Settings → Voice assistants**, open your assistant (or create one), and set **Speech-to-text** to `faster-whisper`.

HA's Wyoming integration uses one language per server. To use Romanian voice commands in HA, either set `WHISPER_LANG=ro` or run a second `faster-whisper` container on another port with `WHISPER_LANG=ro`. Raise that container to `WHISPER_MODEL=medium-int8` if you do: the default `small-int8` is noticeably weaker in Romanian, which is why this server defaults to English only.

---

## 3. Desktop dictation

Press the shortcut to start recording and press it again to stop. The audio is sent to speaches, and the transcript is typed into the focused window.

### Common dependencies

```
pipewire-utils (pw-record)  curl  jq  wl-clipboard  libnotify (notify-send, optional)
```

On Bazzite and other Fedora Atomic systems, add them to your image's Containerfile (`dnf install -y …`) or layer them with `rpm-ostree install`.

The server URL defaults to `http://gb-server:8000`. To change it, set `WHISPER_URL`, or `WHISPER_MODEL` for the model.

### Hyprland

Extra dependency: `wtype`. It types Unicode directly, so Romanian diacritics work.

```bash
install -Dm755 client/dictate.sh ~/.local/bin/dictate.sh
cp client/hyprland/dictate.conf ~/.config/hypr/dictate.conf
echo 'source = ~/.config/hypr/dictate.conf' >> ~/.config/hypr/hyprland.conf
hyprctl reload
```

| Shortcut | Action |
|---|---|
| `Super+D` | Dictate in English |
| `Super+Shift+D` | Dictate in Romanian |

`dictate.conf` also contains a commented-out hold-to-talk variant.

### KDE Plasma 6 (Wayland)

Extra dependency: `ydotool`. KWin doesn't support the virtual-keyboard protocol that `wtype` needs.

```bash
./client/kde/install-kde.sh     # asks for sudo once
# then log out and back in
```

The installer:

1. Installs `dictate.sh` to `~/.local/bin`.
2. Adds a udev rule that gives the `input` group access to `/dev/uinput`, and adds you to that group. On Fedora Atomic, it first copies the group from `/usr/lib/group` into `/etc/group`.
3. Installs and enables `ydotoold` as a systemd user service, and exports `YDOTOOL_SOCKET` through `~/.config/environment.d/`.
4. Installs the two launchers and binds the global shortcuts.

| Shortcut | Action |
|---|---|
| `Meta+Alt+D` | Dictate in English |
| `Meta+Alt+Shift+D` | Dictate in Romanian |

Plasma 6 already uses `Meta+D` for Peek at Desktop. You can rebind both shortcuts in **System Settings → Keyboard → Shortcuts**.

How text is entered on KDE: `ydotool` sends raw US-layout keycodes, so it can't produce ș ț ă î â.
- Transcripts that are plain ASCII are typed as keystrokes.
- Transcripts with diacritics are put on the clipboard and pasted with `Ctrl+Shift+V`, which works in Konsole, kitty, browsers and most editors. Your previous clipboard contents are restored afterwards.

### Troubleshooting

| Symptom | Check |
|---|---|
| Nothing happens on the shortcut | Run `~/.local/bin/dictate.sh en` from a terminal twice to see errors |
| Works from a terminal but not from the shortcut | Add `-v` to the shortcut's command (`… dictate.sh -v en`) and read `~/.local/state/dictate.log`. It records the `WHISPER_URL` the script actually received, what launched it, and curl's result |
| `ydotool: failed to connect socket` | `systemctl --user status ydotoold`, and `echo $YDOTOOL_SOCKET` (log out and back in after installing) |
| `ydotoold` can't open `/dev/uinput` | `ls -l /dev/uinput` should show group `input`; `id` should list `input` |
| "Transcription failed" | The notification shows curl's error. `Could not resolve host` means the client can't resolve `gb-server`: add it to `/etc/hosts` or set `WHISPER_URL` to the IP. Otherwise check `curl http://gb-server:8000/health` |
| KDE shortcut uses an old `WHISPER_URL` after re-running the installer | KWin keeps each launcher's `Exec=` from login time. Log out and back in |
| "Nothing recognised" | The server answered but heard no speech. Is the right microphone the default? Check with `wpctl status` |
| Recording seems stuck | `rm -rf $XDG_RUNTIME_DIR/dictate` |
| Slow transcription | First request after idle loads the model. Otherwise try `WHISPER_MODEL=Systran/faster-whisper-small` |

---

## 4. Other integrations

speaches implements the OpenAI audio API, so most tools only need their base URL changed:

```
OPENAI_BASE_URL=http://gb-server:8000/v1
OPENAI_API_KEY=anything   # required by the SDKs but not checked
```

- **Open WebUI**: Settings → Audio → STT engine "OpenAI", using the URL above
- **n8n / scripts**: a multipart POST to `/v1/audio/transcriptions`, for example to transcribe voice notes dropped into a Nextcloud folder
- **Your own code**: any OpenAI client library, with `model=Systran/faster-whisper-medium`

## 5. Realtime streaming (not set up)

speaches also has an OpenAI-style Realtime WebSocket API that shows words as you speak. On CPU, medium can't keep up with live audio, so expect lag and text that rewrites itself as corrections arrive. If you want to try it, use `Systran/faster-whisper-small` and accept lower accuracy, especially in Romanian. Push-to-talk with medium is the better default.

## References

- [speaches](https://speaches.ai/) ([GitHub](https://github.com/speaches-ai/speaches))
- [linuxserver/faster-whisper](https://github.com/linuxserver/docker-faster-whisper)
- [faster-whisper](https://github.com/SYSTRAN/faster-whisper)
