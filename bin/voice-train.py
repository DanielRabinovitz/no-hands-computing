#!/usr/bin/env python3
"""
voice-train.py — Build a speaker voice profile from WAV files.

Usage:
    voice-train.py --output <path.npy> <wav1> [wav2 ...]

Loads each WAV, extracts a resemblyzer speaker embedding, averages them into
a single profile vector, and saves it with numpy.
"""

import sys
import os
import argparse
import numpy as np

def main():
    parser = argparse.ArgumentParser(
        description="Build a speaker voice profile from WAV files."
    )
    parser.add_argument(
        "--output", "-o",
        default=os.path.expanduser("~/.voice-profile/speaker.npy"),
        help="Path to save the profile .npy file (default: ~/.voice-profile/speaker.npy)"
    )
    parser.add_argument(
        "wav_files",
        nargs="+",
        metavar="WAV",
        help="WAV audio files to embed (16kHz mono recommended)"
    )
    args = parser.parse_args()

    # Late import so argument errors surface cleanly before the slow torch load
    try:
        from resemblyzer import VoiceEncoder, preprocess_wav
        from pathlib import Path
    except ImportError as e:
        print(f"[ERROR] Could not import resemblyzer: {e}", file=sys.stderr)
        print("        pip3 install --break-system-packages resemblyzer", file=sys.stderr)
        sys.exit(1)

    output_path = os.path.expanduser(args.output)
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    print("[INFO] Loading VoiceEncoder model...", flush=True)
    encoder = VoiceEncoder()

    embeddings = []
    total_seconds = 0.0
    failed = 0

    for i, wav_path in enumerate(args.wav_files):
        print(f"[{i+1}/{len(args.wav_files)}] Processing: {os.path.basename(wav_path)}", flush=True)

        if not os.path.isfile(wav_path):
            print(f"         [WARN] File not found, skipping: {wav_path}", file=sys.stderr)
            failed += 1
            continue

        try:
            wav = preprocess_wav(Path(wav_path))

            if len(wav) == 0:
                print(f"         [WARN] Empty audio, skipping: {wav_path}", file=sys.stderr)
                failed += 1
                continue

            duration = len(wav) / 16000.0

            # embed_utterance returns a single 256-dim vector for the whole clip
            embedding = encoder.embed_utterance(wav)

            embeddings.append(embedding)
            total_seconds += duration
            print(f"         -> {duration:.1f}s, embedding norm: {np.linalg.norm(embedding):.4f}", flush=True)

        except Exception as e:
            print(f"         [WARN] Failed to process {wav_path}: {e}", file=sys.stderr)
            failed += 1
            continue

    if not embeddings:
        print("[ERROR] No embeddings produced. Cannot build profile.", file=sys.stderr)
        sys.exit(1)

    # Average all embeddings and re-normalise to unit length
    profile = np.mean(embeddings, axis=0)
    profile_norm = np.linalg.norm(profile)
    if profile_norm > 0:
        profile = profile / profile_norm

    np.save(output_path, profile)

    print("")
    print(f"[RESULT] Files processed : {len(embeddings)} succeeded, {failed} failed")
    print(f"[RESULT] Total audio used : {total_seconds:.1f} seconds ({total_seconds/60:.1f} minutes)")
    print(f"[RESULT] Embedding shape  : {profile.shape}")
    print(f"[RESULT] Final norm       : {np.linalg.norm(profile):.6f}  (should be ~1.0)")
    print(f"[RESULT] Profile saved to : {output_path}")

if __name__ == "__main__":
    main()
