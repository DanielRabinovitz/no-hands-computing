#!/usr/bin/env bash
# voice-train.sh — Build a speaker voice profile from video files in ~/Dropbox
# Usage: voice-train.sh
# Saves profile to ~/.voice-profile/speaker.npy

set -euo pipefail

PROFILE_DIR="$HOME/.voice-profile"
PROFILE_PATH="$PROFILE_DIR/speaker.npy"
TRAIN_SCRIPT="$HOME/bin/voice-train.py"
SEARCH_ROOT="$HOME/Dropbox"
TMPDIR_BASE="/tmp/voice-train-$$"

# ── Dependency checks ──────────────────────────────────────────────────────────
if ! command -v ffmpeg &>/dev/null; then
    echo "[ERROR] ffmpeg is not installed." >&2
    echo "        Install it with:" >&2
    echo "          sudo apt install ffmpeg" >&2
    exit 1
fi

if ! python3 -c "import resemblyzer" &>/dev/null; then
    echo "[ERROR] resemblyzer Python package is not installed." >&2
    echo "        Install it with:" >&2
    echo "          pip3 install --break-system-packages resemblyzer" >&2
    exit 1
fi

if [[ ! -f "$TRAIN_SCRIPT" ]]; then
    echo "[ERROR] Training script not found: $TRAIN_SCRIPT" >&2
    exit 1
fi

# ── Setup ──────────────────────────────────────────────────────────────────────
mkdir -p "$PROFILE_DIR"
mkdir -p "$TMPDIR_BASE"
trap 'echo "[INFO] Cleaning up temp files..."; rm -rf "$TMPDIR_BASE"' EXIT

echo "[INFO] Searching for video files under: $SEARCH_ROOT"
echo "[INFO] Looking for: *.mp4, *.mov, *.MOV, *.m4v"
echo ""

# ── Find video files ───────────────────────────────────────────────────────────
mapfile -d '' VIDEO_FILES < <(
    find "$SEARCH_ROOT" \
        \( -name "*.mp4" -o -name "*.mov" -o -name "*.MOV" -o -name "*.m4v" \) \
        -type f -print0 2>/dev/null
)

if [[ ${#VIDEO_FILES[@]} -eq 0 ]]; then
    echo "[WARN] No video files found under $SEARCH_ROOT" >&2
    echo "       Check that Dropbox has synced and videos are present." >&2
    exit 1
fi

echo "[INFO] Found ${#VIDEO_FILES[@]} video file(s)."
echo ""

# ── Extract audio from each video ─────────────────────────────────────────────
WAV_FILES=()
FAILED=0

for i in "${!VIDEO_FILES[@]}"; do
    VIDEO="${VIDEO_FILES[$i]}"
    BASENAME=$(basename "$VIDEO")
    # Strip extension, sanitize name
    STEM="${BASENAME%.*}"
    SAFE_STEM=$(echo "$STEM" | tr -cd '[:alnum:]._-' | cut -c1-80)
    WAV_OUT="$TMPDIR_BASE/${i}_${SAFE_STEM}.wav"

    echo "[${i+1}/${#VIDEO_FILES[@]}] Extracting audio: $BASENAME"

    if ffmpeg -y -i "$VIDEO" \
              -ac 1 -ar 16000 \
              -vn \
              -loglevel error \
              "$WAV_OUT" 2>/tmp/ffmpeg-err-$$; then
        WAV_FILES+=("$WAV_OUT")
        echo "           -> OK: $WAV_OUT"
    else
        FFMPEG_ERR=$(cat /tmp/ffmpeg-err-$$ 2>/dev/null || true)
        echo "[WARN]     -> FAILED to extract audio from: $BASENAME"
        [[ -n "$FFMPEG_ERR" ]] && echo "           ffmpeg: $FFMPEG_ERR"
        (( FAILED++ )) || true
    fi
done

rm -f /tmp/ffmpeg-err-$$

echo ""
echo "[INFO] Extracted audio from $((${#VIDEO_FILES[@]} - FAILED)) / ${#VIDEO_FILES[@]} video(s)."

if [[ ${#WAV_FILES[@]} -eq 0 ]]; then
    echo "[ERROR] No audio files were successfully extracted. Cannot build profile." >&2
    exit 1
fi

# ── Run the Python training script ────────────────────────────────────────────
echo ""
echo "[INFO] Running speaker embedding trainer..."
echo "[INFO] Output profile: $PROFILE_PATH"
echo ""

python3 "$TRAIN_SCRIPT" --output "$PROFILE_PATH" "${WAV_FILES[@]}"

EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    echo ""
    echo "[OK] Voice profile saved to: $PROFILE_PATH"
    [[ $FAILED -gt 0 ]] && echo "[WARN] $FAILED video(s) failed audio extraction (skipped)."
else
    echo "[ERROR] Training script failed with exit code $EXIT_CODE" >&2
    exit $EXIT_CODE
fi
