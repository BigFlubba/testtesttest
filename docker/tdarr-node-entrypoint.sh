#!/usr/bin/env bash
# Starts Tdarr_Node using the ffmpeg / HandBrakeCLI / mkvpropedit baked into this image.
# Server connection comes from env: serverIP, serverPort, nodeName (docker run -e ...)
set -euo pipefail

: "${rootDataPath:=/data/tdarr}"
mkdir -p "$rootDataPath/configs" "$rootDataPath/logs"
CFG="$rootDataPath/configs/Tdarr_Node_Config.json"

# Point Tdarr at our binaries (create the config or patch the existing one)
[ -f "$CFG" ] || echo '{}' > "$CFG"
tmp="$(mktemp)"
jq --arg ff "$(command -v ffmpeg)" \
   --arg hb "$(command -v HandBrakeCLI)" \
   --arg mk "$(command -v mkvpropedit)" \
   '.ffmpegPath=$ff | .handbrakePath=$hb | .mkvpropeditPath=$mk' "$CFG" > "$tmp"
cat "$tmp" > "$CFG"; rm -f "$tmp"

echo "Tdarr Node $(cat /opt/tdarr/VERSION 2>/dev/null) | $(ffmpeg -version | head -1) | $(HandBrakeCLI --version 2>&1 | head -1)"
cd "$rootDataPath"
exec /opt/tdarr/node/Tdarr_Node "$@"
