# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A deployment/config repo, not an application: a Docker Compose stack plus shell and desktop-integration
files for self-hosted Whisper speech-to-text. There is no build step, no test suite, and no package
manifest — everything is `compose.yaml`, bash, `.desktop`, systemd and udev files. Validate changes by
running them, not by running a test runner.

## Architecture

Two independent containers sharing nothing but the host. They are separate processes, so each loads its
*own* copy of its model into its own memory — a shared volume can dedupe models on disk but never in RAM,
which is why the two run *different* model sizes rather than one shared copy:

- **speaches** (`:8000`) — OpenAI-compatible REST (`POST /v1/audio/transcriptions`). Consumed by
  `client/dictate.sh`, curl, Open WebUI, n8n. Runs **medium** (~1.5–2 GB): model is chosen per request
  (`model=Systran/faster-whisper-medium`), loaded lazily and unloaded after idle, so the first call after
  a pause is slow. This is the path that serves Romanian.
- **faster-whisper** (`:10300`) — Wyoming protocol, consumed only by Home Assistant. Runs **small-int8**
  (~0.5 GB, always resident) because `WHISPER_LANG=en` pins it to English, where the accuracy gap to
  medium is small. Model and language are fixed at container level via `WHISPER_MODEL` / `WHISPER_LANG`;
  one language per server, so Romanian HA voice means flipping `WHISPER_LANG` (and raising the model back
  to `medium-int8`) or adding a second container on another port.

`WHISPER_MODEL` is passed verbatim to `wyoming_faster_whisper --model`, which accepts the `<size>-int8`
shorthands (rewritten to `rhasspy/faster-whisper-<size>-int8`), any HF repo id, or an absolute local path.
Models land in `server/faster-whisper/` as an HF-hub cache (`models--<org>--<repo>/snapshots/<rev>/`), and
superseded repos are not pruned automatically.

The host is referred to as `gb-server` throughout. The client's server URL is overridable via `WHISPER_URL`
(and model via `WHISPER_MODEL`), but that hostname is also **hardcoded in three other places** that must be
kept in sync when it changes: `client/hyprland/dictate.conf` (`env =` line) and both
`client/kde/dictate-*.desktop` (`Exec=env WHISPER_URL=…`).

## dictate.sh

Single script, two desktop environments, invoked as `dictate.sh en|ro`. It is a *toggle*: state lives in
`$XDG_RUNTIME_DIR/dictate/rec.pid`; the first press starts `pw-record` in the background, the second press
kills it, POSTs the wav, and injects the text. A stale pid file is the usual "recording stuck" failure —
`rm -rf $XDG_RUNTIME_DIR/dictate`.

Text injection branches on compositor, and this is the subtle part:

- Hyprland (detected via `HYPRLAND_INSTANCE_SIGNATURE`) uses `wtype`, which handles Unicode, so Romanian
  diacritics type directly.
- KDE/KWin has no virtual-keyboard protocol, so it uses `ydotool`, which emits **raw US-layout keycodes**
  and therefore cannot produce ș ț ă î â. Non-ASCII transcripts fall back to `paste_text()`: copy to
  clipboard, send `Ctrl+Shift+V` as literal keycodes (`29:1 42:1 47:1 …`), restore the old clipboard.
  Any change to injection must preserve this ASCII/non-ASCII split.
- Fallback with neither tool: clipboard + notification.

## KDE install

`client/kde/install-kde.sh` is the one piece with real side effects (sudo, udev, group membership, systemd
user unit, `kwriteconfig6` global shortcuts) and is written for Bazzite / Fedora Atomic — hence the
`/usr/lib/group` → `/etc/group` copy for the `input` group and `~/.config/environment.d` for
`YDOTOOL_SOCKET`. It requires a logout to take effect, so changes to it can't be verified in-session.
`.desktop` `Exec=` cannot expand `~`/`$HOME`, which is why the files ship `@HOME@` and the installer `sed`s
it; keep that placeholder if editing them.

## Common commands

```bash
cd server && docker compose up -d                  # podman compose also works
curl -X POST http://localhost:8000/v1/models/Systran/faster-whisper-medium   # one-time model download
docker logs -f faster-whisper                      # model download progress

# end-to-end check of the REST path
pw-record --rate 16000 --channels 1 --format s16 test.wav & sleep 5; kill %1
curl http://gb-server:8000/v1/audio/transcriptions -F file=@test.wav \
  -F model=Systran/faster-whisper-medium -F language=en

~/.local/bin/dictate.sh en                         # run twice to see client errors in a terminal
systemctl --user status ydotoold
```

## Conventions

The README is the user-facing documentation and is detailed; keep it in sync with any change to ports,
env vars, shortcuts or install steps, including its troubleshooting table. Comments in these files explain
*why* (RAM cost, keycode numbers, Atomic-distro quirks) — match that density rather than annotating the
obvious.
