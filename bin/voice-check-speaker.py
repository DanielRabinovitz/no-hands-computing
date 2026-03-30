#!/usr/bin/env python3
"""
voice-check-speaker.py — Gate audio chunks by speaker identity.

Usage:
    voice-check-speaker.py <wav_file>

Exit codes:
    0  — speaker matches profile (or no profile exists yet → fail open)
    1  — speaker does NOT match profile

Similarity score is printed to stderr for debugging.

Designed to be called in the voice-listen.sh loop AFTER recording but
BEFORE transcription, e.g.:

    arecord -d 4 -f cd -t wav /tmp/voice_chunk.wav 2>/dev/null
    if voice-check-speaker.py /tmp/voice_chunk.wav; then
        # transcribe & route
    fi
"""

import sys
import os
import numpy as np

PROFILE_PATH = os.path.expanduser("~/.voice-profile/speaker.npy")
SIMILARITY_THRESHOLD = 0.75


def cosine_similarity(a: np.ndarray, b: np.ndarray) -> float:
    """Cosine similarity between two 1-D vectors."""
    norm_a = np.linalg.norm(a)
    norm_b = np.linalg.norm(b)
    if norm_a == 0 or norm_b == 0:
        return 0.0
    return float(np.dot(a, b) / (norm_a * norm_b))


def main():
    if len(sys.argv) < 2:
        print("[ERROR] Usage: voice-check-speaker.py <wav_file>", file=sys.stderr)
        sys.exit(1)

    wav_path = sys.argv[1]

    # ── No profile yet: fail open ──────────────────────────────────────────────
    if not os.path.isfile(PROFILE_PATH):
        print(f"[SPEAKER] No profile at {PROFILE_PATH} — failing open (exit 0)", file=sys.stderr)
        sys.exit(0)

    # ── Load profile ──────────────────────────────────────────────────────────
    try:
        profile = np.load(PROFILE_PATH)
    except Exception as e:
        print(f"[SPEAKER] Could not load profile: {e} — failing open (exit 0)", file=sys.stderr)
        sys.exit(0)

    # ── Check input file ──────────────────────────────────────────────────────
    if not os.path.isfile(wav_path):
        print(f"[SPEAKER] WAV file not found: {wav_path}", file=sys.stderr)
        sys.exit(1)

    # ── Late import (torch/resemblyzer is slow; only load if profile exists) ──
    try:
        from resemblyzer import VoiceEncoder, preprocess_wav
        from pathlib import Path
    except ImportError as e:
        print(f"[SPEAKER] resemblyzer not available: {e} — failing open (exit 0)", file=sys.stderr)
        sys.exit(0)

    # ── Embed the audio chunk ─────────────────────────────────────────────────
    try:
        encoder = VoiceEncoder()
        wav = preprocess_wav(Path(wav_path))

        if len(wav) == 0:
            print("[SPEAKER] Empty audio chunk — failing open (exit 0)", file=sys.stderr)
            sys.exit(0)

        embedding = encoder.embed_utterance(wav)

    except Exception as e:
        print(f"[SPEAKER] Embedding failed: {e} — failing open (exit 0)", file=sys.stderr)
        sys.exit(0)

    # ── Compare to profile ────────────────────────────────────────────────────
    similarity = cosine_similarity(profile, embedding)

    if similarity >= SIMILARITY_THRESHOLD:
        print(f"[SPEAKER] similarity={similarity:.4f} >= {SIMILARITY_THRESHOLD} — MATCH (exit 0)", file=sys.stderr)
        sys.exit(0)
    else:
        print(f"[SPEAKER] similarity={similarity:.4f} < {SIMILARITY_THRESHOLD} — NO MATCH (exit 1)", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
