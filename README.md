# LM Studio Launcher

Lightweight Bash launcher for LM Studio (AppImage). Starts the app and checks for updates, and if an update is found downloads and installs it automatically.

## Quick install

```bash
# make executable and place in your PATH
chmod +x lm-studio-launcher.sh
ln -s lm-studio-launcher.sh ~/bin/lm-studio

# run once to download and start LM Studio
lm-studio
```

## Usage

Run the launcher from a terminal. Replace `lm-studio` below with the path/name you used when installing the script (for example `~/bin/lm-studio`).

- Launch (default): start the locally installed AppImage immediately. If none exists the launcher will download the latest and then start it.

```bash
lm-studio [args...]
```

- Wait for update then launch: resolve and download the latest AppImage first (foreground), then start it.

```bash
lm-studio --wait-update [args...]
```

- Save a custom seed URL used to resolve the live AppImage URL:
```bash
lm-studio --seed <URL>
```

- Clear a previously saved seed URL:
```bash
lm-studio --clear-seed
```

- Force the launcher to re-resolve the latest URL on next run:
```bash
lm-studio --refresh
```

Notes:
- `[args...]` are passed through to the LM Studio AppImage when it is executed.

## Configuration (environment variables)

The script uses sensible defaults and stores AppImages under `~/.apps/lm-studio/`. Customize behavior using environment variables before running the script:

- `APPDIR` — directory to store AppImages and metadata (default: `$HOME/.apps/lm-studio`).
- `KEEP_N` — how many historical AppImages to keep (default: `4`).
- `TTL_SEC` — how long the resolved-URL cache is valid in seconds (default: `21600`, i.e. 6 hours).
- `CURL_BIN` — path to `curl` if not on PATH.
- `LMSTUDIO_VERBOSE` — set to `0` to silence progress messages (default: `1`).
- `LMSTUDIO_DEBUG` — set to `1` to enable shell `set -x` debugging.

Example overriding `KEEP_N` and `APPDIR`:

```bash
APPDIR="$HOME/.local/share/lm-studio" KEEP_N=6 lm-studio
```

## How updates work

1. The script resolves the official "latest" installer URL (default seed is `https://lmstudio.ai/download/latest/linux/x64`).
2. It downloads the AppImage with `curl` using resume support (`-C -`) and saves it as `LM-Studio-<version>.AppImage` in `APPDIR`.
3. After download the script creates/updates a stable symlink `LM-Studio-latest.AppImage` pointing to the latest file and prunes older files beyond `KEEP_N`.
4. The script stores ETag/Last-Modified headers and uses them to avoid re-downloading unchanged files.

If a background update finishes while LM Studio is running the script will notify you and (when possible) prompt to restart the app. If the user accepts, the script attempts a graceful shutdown of the existing LM Studio process and starts the new one.

## Troubleshooting

- If the launcher cannot resolve the latest URL, use the `--seed` subcommand to provide a working seed URL:

```bash
lm-studio --seed 'https://lmstudio.ai/download/latest/linux/x64'
```

- If desktop notifications don't appear, ensure `notify-send` is installed and that you are running a graphical session (X11 or Wayland).
- If downloads fail repeatedly, check network connectivity and that `curl` is available. You can provide an alternate `curl` binary using `CURL_BIN`.
