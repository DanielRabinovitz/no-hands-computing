# Audio Cues

These `.wav` files are played as audible feedback during the voice pipeline.
They are generated with Piper TTS and are not committed to the repo (binary files).

## Generate them yourself

```bash
PIPER_MODEL="$HOME/models/piper/en_US-lessac-medium.onnx"
mkdir -p ~/.voice-profile

for phrase in \
  "listening:listening" \
  "listening off:listening_off" \
  "not sure what you said:low_confidence" \
  "not sure if you said something:empty_result" \
  "got it:got_it"; do
  text="${phrase%%:*}"
  name="${phrase##*:}"
  echo "$text" | piper --model "$PIPER_MODEL" --output_file ~/.voice-profile/${name}.wav
done

echo "Audio cues generated in ~/.voice-profile/"
```

## Files

| Filename | Phrase | When it plays |
|---|---|---|
| `listening.wav` | "Listening." | PTT key pressed — mic is open |
| `listening_off.wav` | "Listening off." | PTT key pressed again — mic closed |
| `low_confidence.wav` | "Not sure what you said." | STT confidence too low |
| `empty_result.wav` | "Not sure if you said something." | STT returned empty text |
| `got_it.wav` | "Got it." | (generated, reserved for future use) |
