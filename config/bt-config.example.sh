#!/bin/bash
# bt-config.example.sh — Bluetooth headset configuration
#
# Add these exports to your ~/.bashrc (or source this file from it).
# Replace the values with your own headset's card and source names.
#
# To find your values:
#   pactl list cards short    → shows BT_CARD name
#   pactl list sources short  → shows BT_SOURCE name

export BT_CARD="bluez_card.XX_XX_XX_XX_XX_XX"
export BT_SOURCE="bluez_input.XX_XX_XX_XX_XX_XX.0"
