#!/bin/bash
#
# Set up FreeFlow with a fully local speech + LLM stack on an Apple Silicon Mac.
#
#   ASR : speech-server (Parakeet TDT v3, CoreML/ANE)  -> http://127.0.0.1:<port>/v1
#   LLM : Ollama (cleanup model, see --list-models)    -> http://127.0.0.1:11434/v1
#
# Both are registered with launchd so they come back after a reboot, and both
# models are preloaded at login so the first dictation of the day is instant.
#
# Usage:
#   ./setup.sh                 # install + configure + verify
#   ./setup.sh --model light   # use a smaller cleanup model (see --list-models)
#   ./setup.sh --port 8200     # use a different ASR port
#   ./setup.sh --yes           # don't prompt before quitting/relaunching FreeFlow
#   ./setup.sh --list-models   # show cleanup model options and exit
#   ./setup.sh --uninstall     # remove the launch agent + helper files
#
set -euo pipefail

ASR_PORT=8123
OLLAMA_PORT=11434
ASR_MODEL="parakeet"

# Cleanup-model tiers. RAM and accuracy figures are measured, not estimated:
# each model was scored on 15 cases built from FreeFlow's own system prompt
# (filler removal, self-corrections, list formatting, identifier preservation,
# and the "echo instructions, never execute them" rule). See the README.
LLM_TIER="quality"
tier_model() {
  case "$1" in
    quality)  echo "qwen3:4b-instruct-2507-q4_K_M" ;;
    balanced) echo "granite4:3b" ;;
    light)    echo "qwen2.5:1.5b" ;;
    *)        echo "$1" ;;   # anything else: treat as a literal Ollama tag
  esac
}

list_models() {
  cat <<'MODELS'
Cleanup model options (--model <tier>):

  quality    qwen3:4b-instruct-2507-q4_K_M    2.9 GB RAM   ~0.43s   [default]
             Best all-round. Passed every English behavior test.

  balanced   granite4:3b                      2.3 GB RAM   ~0.40s
             Matches quality on English and is 0.6 GB lighter. Slightly
             rougher on non-English text.

  light      qwen2.5:1.5b                     1.1 GB RAM   ~0.24s
             Fastest, less than half the RAM. Trade-offs: does not format
             spoken lists as bullet lists, and may ANSWER a dictated
             question instead of transcribing it.

You can also pass any Ollama tag directly, e.g. --model llama3.2:3b.
Avoid reasoning models (qwen3:1.7b, deepseek-r1): FreeFlow only strips
<think> tags for two hardcoded cloud model names, so their reasoning would
be typed into your text field.
MODELS
}
LABEL="audio.soniqo.speech-server"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LAUNCHER="$HOME/.local/bin/speech-server-launch.sh"
WARM_WAV="$HOME/.cache/speech-server/warm.wav"
FF_BUNDLE="com.zachlatta.freeflow"
FF_SETTINGS="$HOME/Library/Application Support/FreeFlow/.settings"
ASSUME_YES=0
DO_UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) ASR_PORT="$2"; shift 2 ;;
    --model) LLM_TIER="$2"; shift 2 ;;
    --list-models) list_models; exit 0 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --uninstall) DO_UNINSTALL=1; shift ;;
    # Print the header comment, however long it grows.
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

LLM_MODEL="$(tier_model "$LLM_TIER")"

say_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
say_ok()   { printf '    \033[32m✓\033[0m %s\n' "$*"; }
say_warn() { printf '    \033[33m!\033[0m %s\n' "$*"; }
die()      { printf '\n\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- uninstall --
if [ "$DO_UNINSTALL" = 1 ]; then
  say_step "Removing local stack"
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$LAUNCHER" "$WARM_WAV"
  say_ok "launch agent + helper files removed (models and Homebrew packages kept)"
  echo "    To also remove them: brew uninstall speech && ollama rm $LLM_MODEL"
  exit 0
fi

# --------------------------------------------------------------- preflight ---
say_step "Checking prerequisites"

[ "$(uname -s)" = "Darwin" ] || die "This script is macOS only."
[ "$(uname -m)" = "arm64" ] || die "Apple Silicon required — the speech models are arm64/CoreML only."

os_major=$(sw_vers -productVersion | cut -d. -f1)
[ "$os_major" -ge 15 ] || die "macOS 15 or newer required (found $(sw_vers -productVersion))."

[ -x /opt/homebrew/bin/brew ] || die "Native ARM Homebrew not found at /opt/homebrew. Install it from https://brew.sh first."
eval "$(/opt/homebrew/bin/brew shellenv)"
say_ok "Apple Silicon, macOS $(sw_vers -productVersion), Homebrew OK"

[ -d /Applications/FreeFlow.app ] || say_warn "FreeFlow.app not in /Applications — download it from https://github.com/zachlatta/freeflow/releases/latest and re-run to auto-configure it."

# Port 8080 is a common collision (Docker, dev servers). Find a free port —
# but if the port is already ours from a previous run, keep using it.
port_free() { ! nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
port_is_ours() { curl -sf -m 2 "http://127.0.0.1:$1/health" 2>/dev/null | grep -q '"ok"'; }
# A server we just stopped can hold the socket for a few seconds — wait it out
# before concluding the port belongs to someone else.
if ! port_free "$ASR_PORT" && ! port_is_ours "$ASR_PORT"; then
  for _ in 1 2 3 4 5 6; do
    sleep 1
    port_free "$ASR_PORT" && break
  done
fi
if ! port_free "$ASR_PORT" && ! port_is_ours "$ASR_PORT"; then
  say_warn "port $ASR_PORT is in use by another process"
  for candidate in 8124 8125 8180 8199; do
    if port_free "$candidate" || port_is_ours "$candidate"; then ASR_PORT="$candidate"; break; fi
  done
  { port_free "$ASR_PORT" || port_is_ours "$ASR_PORT"; } \
    || die "Could not find a free port. Pass one explicitly: ./setup.sh --port 9100"
fi
say_ok "ASR port: $ASR_PORT"

# ----------------------------------------------------------------- install ---
say_step "Installing speech-server and Ollama (Homebrew)"
brew list --versions speech >/dev/null 2>&1 || brew install speech
brew list --versions ollama >/dev/null 2>&1 || brew install ollama
say_ok "speech $(brew list --versions speech | awk '{print $2}'), ollama $(brew list --versions ollama | awk '{print $2}')"

say_step "Configuring Ollama to keep models resident"
# `brew services start` writes the launch agent if it doesn't exist yet. After
# this point we reload it with launchctl directly — any later `brew services`
# command regenerates the plist and drops the environment variables below.
brew services start ollama >/dev/null 2>&1 || true
OLLAMA_PLIST="$HOME/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
if [ -f "$OLLAMA_PLIST" ]; then
  /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables dict" "$OLLAMA_PLIST" 2>/dev/null || true
  # 24h rather than -1: it survives brew's plist parsing and is effectively
  # "never unload" for a workday.
  for kv in "OLLAMA_KEEP_ALIVE:24h" "OLLAMA_FLASH_ATTENTION:1"; do
    k="${kv%%:*}"; v="${kv#*:}"
    /usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:$k string $v" "$OLLAMA_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Set :EnvironmentVariables:$k $v" "$OLLAMA_PLIST"
  done
  # bootout needs a moment to release the label before bootstrap can claim it;
  # bootstrapping too early leaves the service unloaded entirely.
  launchctl bootout "gui/$UID/homebrew.mxcl.ollama" 2>/dev/null || true
  sleep 2
  if ! launchctl bootstrap "gui/$UID" "$OLLAMA_PLIST" 2>/dev/null; then
    say_warn "launchctl bootstrap failed; falling back to brew services (models will unload after 5min idle)"
    brew services start ollama >/dev/null 2>&1 || true
  else
    say_ok "OLLAMA_KEEP_ALIVE=24h (model stays resident), flash attention on"
  fi
else
  say_warn "Ollama launch agent not found; run 'brew services start ollama' manually."
fi

for _ in $(seq 1 60); do
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$OLLAMA_PORT/api/tags" && break
  sleep 1
done

say_step "Pulling the cleanup model ($LLM_MODEL)"
case "$LLM_MODEL" in
  qwen3:0.6b|qwen3:1.7b|qwen3:4b|qwen3:8b|deepseek-r1*)
    say_warn "$LLM_MODEL is a reasoning model — FreeFlow does not strip its <think>"
    say_warn "tags, so they will be typed into your text. Use --list-models for options."
    ;;
esac
if ollama list 2>/dev/null | grep -q "^${LLM_MODEL}[[:space:]]"; then
  say_ok "already present"
else
  ollama pull "$LLM_MODEL"
fi

# ------------------------------------------------------------ launch agent ---
say_step "Installing the launch agent (starts at login, restarts on crash)"

mkdir -p "$HOME/.local/bin" "$(dirname "$WARM_WAV")"
say "Warm up the model." -o "$WARM_WAV" --file-format=WAVE --data-format=LEI16@16000

cat > "$LAUNCHER" <<LAUNCHER_EOF
#!/bin/bash
# Generated by freeflow-local-setup. Starts speech-server and preloads both
# models so the first dictation after a reboot doesn't pay the load cost.

PORT=$ASR_PORT
WARM_WAV="\$HOME/.cache/speech-server/warm.wav"
WARM_MARKER="\$HOME/.cache/speech-server/.warm"

rm -f "\$WARM_MARKER"

/opt/homebrew/bin/speech-server --host 127.0.0.1 --port "\$PORT" &
server_pid=\$!

(
  for _ in \$(seq 1 120); do
    curl -sf -m 2 -o /dev/null "http://127.0.0.1:\$PORT/health" && break
    sleep 1
  done
  [ -f "\$WARM_WAV" ] && curl -sf -m 600 -o /dev/null \\
    -F "file=@\$WARM_WAV" -F model=$ASR_MODEL \\
    "http://127.0.0.1:\$PORT/v1/audio/transcriptions"
  # Signals "ASR model loaded, safe to send requests". speech-server has a data
  # race in its model cache (segfault in ModelState.loadParakeet) if a second
  # request arrives while the first is still loading the model.
  touch "\$WARM_MARKER"

  curl -sf -m 600 -o /dev/null http://127.0.0.1:$OLLAMA_PORT/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"$LLM_MODEL","messages":[{"role":"user","content":"hi"}],"max_tokens":1}'
) &

wait "\$server_pid"
LAUNCHER_EOF
chmod +x "$LAUNCHER"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$LAUNCHER</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/tmp/speech-server.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/speech-server.log</string>
</dict>
</plist>
PLIST_EOF

plutil -lint "$PLIST" >/dev/null || die "generated plist is invalid"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST" || die "launchctl could not load $PLIST"
say_ok "launch agent installed ($LABEL)"

printf '    waiting for the ASR model to download/load (first run: several minutes)'
for _ in $(seq 1 900); do
  curl -sf -m 2 -o /dev/null "http://127.0.0.1:$ASR_PORT/health" && break
  printf '.'; sleep 1
done
printf '\n'
curl -sf -m 2 -o /dev/null "http://127.0.0.1:$ASR_PORT/health" || die "speech-server did not come up — check /tmp/speech-server.log"
say_ok "speech-server listening on 127.0.0.1:$ASR_PORT"

# Wait for the launcher's warmup request to finish before sending our own —
# overlapping requests during model load crash the server.
printf '    waiting for the model to finish loading'
for _ in $(seq 1 900); do
  [ -f "$HOME/.cache/speech-server/.warm" ] && break
  printf '.'; sleep 1
done
printf '\n'
[ -f "$HOME/.cache/speech-server/.warm" ] || say_warn "warmup did not signal completion; continuing anyway"

# --------------------------------------------------------- configure app -----
say_step "Configuring FreeFlow"

if [ -d /Applications/FreeFlow.app ]; then
  ff_was_running=0
  if pgrep -qf "FreeFlow.app/Contents/MacOS/FreeFlow"; then
    ff_was_running=1
    if [ "$ASSUME_YES" = 0 ]; then
      read -r -p "    FreeFlow is running and must be restarted to apply settings. Quit it now? [y/N] " reply
      case "$reply" in [yY]*) ;; *) die "Aborted. Re-run with --yes, or quit FreeFlow and run again." ;; esac
    fi
    osascript -e 'quit app "FreeFlow"' >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -qf "FreeFlow.app/Contents/MacOS/FreeFlow" || break; sleep 0.5; done
  fi

  mkdir -p "$(dirname "$FF_SETTINGS")"
  [ -f "$FF_SETTINGS" ] || printf '{}' > "$FF_SETTINGS"
  plutil -replace api_base_url          -string "http://127.0.0.1:$OLLAMA_PORT/v1" "$FF_SETTINGS"
  plutil -replace transcription_api_url -string "http://127.0.0.1:$ASR_PORT/v1"    "$FF_SETTINGS"
  # Any non-empty key works — Ollama and speech-server both ignore Authorization.
  if ! plutil -extract groq_api_key raw "$FF_SETTINGS" >/dev/null 2>&1; then
    plutil -replace groq_api_key -string "local" "$FF_SETTINGS"
  fi
  chmod 600 "$FF_SETTINGS"

  defaults write "$FF_BUNDLE" transcription_model           -string "$ASR_MODEL"
  defaults write "$FF_BUNDLE" post_processing_model         -string "$LLM_MODEL"
  defaults write "$FF_BUNDLE" post_processing_fallback_model -string "$LLM_MODEL"
  defaults write "$FF_BUNDLE" context_model                 -string "$LLM_MODEL"
  # speech-server rejects the WebSocket upgrade FreeFlow sends (it compares the
  # raw path including "?intent=transcription"), and never emits transcript
  # deltas anyway — so streaming buys nothing here. The batch path is ~0.15s.
  defaults write "$FF_BUNDLE" realtime_streaming_enabled    -bool false
  # Local first-load can exceed the 20s default.
  defaults write "$FF_BUNDLE" transcription_timeout_seconds   -float 60
  defaults write "$FF_BUNDLE" post_processing_timeout_seconds -float 60
  defaults write "$FF_BUNDLE" context_request_timeout_seconds -float 60
  say_ok "FreeFlow pointed at the local stack"

  if [ "$ff_was_running" = 1 ]; then
    open -a FreeFlow
    say_ok "FreeFlow relaunched"
  fi
else
  say_warn "skipped — FreeFlow.app is not installed"
fi

# -------------------------------------------------------------- verify -------
say_step "Verifying"

asr_out=""
for attempt in 1 2 3; do
  asr_start=$(date +%s.%N)
  asr_out=$(curl -sf -m 120 -F "file=@$WARM_WAV" -F "model=$ASR_MODEL" \
    "http://127.0.0.1:$ASR_PORT/v1/audio/transcriptions" || true)
  asr_ms=$(echo "($(date +%s.%N) - $asr_start) * 1000" | bc | cut -d. -f1)
  [ -n "$asr_out" ] && break
  say_warn "attempt $attempt failed; the server may be restarting"
  sleep 12
done
echo "$asr_out" | grep -qi "warm up" \
  && say_ok "transcription OK (${asr_ms}ms): $(echo "$asr_out" | tr -d '\n' | sed 's/.*"text" *: *"\([^"]*\)".*/\1/')" \
  || die "transcription failed. Response: $asr_out"

llm_start=$(date +%s.%N)
llm_out=$(curl -sf -m 120 "http://127.0.0.1:$OLLAMA_PORT/v1/chat/completions" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"$LLM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}],\"max_tokens\":10}" || true)
llm_ms=$(echo "($(date +%s.%N) - $llm_start) * 1000" | bc | cut -d. -f1)
echo "$llm_out" | grep -q '"content"' \
  && say_ok "LLM cleanup OK (${llm_ms}ms)" \
  || die "LLM request failed. Response: $llm_out"

cat <<SUMMARY

$(printf '\033[1mDone.\033[0m') Everything starts automatically at login.

  ASR   http://127.0.0.1:$ASR_PORT/v1     (speech-server, model: $ASR_MODEL)
  LLM   http://127.0.0.1:$OLLAMA_PORT/v1    (ollama, model: $LLM_MODEL)
  Logs  /tmp/speech-server.log

If this is a fresh FreeFlow install, open it and finish the setup wizard:
grant Microphone and Accessibility access, and when it asks for an API key
type "local" (it validates against your local Ollama, so it will pass).

Useful commands:
  launchctl kickstart -k gui/\$UID/$LABEL            # restart the ASR server
  launchctl kickstart -k gui/\$UID/homebrew.mxcl.ollama  # restart the LLM server
  tail -f /tmp/speech-server.log                      # watch ASR logs
  ./setup.sh --list-models                            # cleanup model options
  ./setup.sh --model light                            # switch to a smaller model
  ./setup.sh --uninstall                              # remove the launch agent

Note: restart Ollama with launchctl, not 'brew services restart ollama' —
brew regenerates its launch agent and drops OLLAMA_KEEP_ALIVE, which makes the
model unload after 5 minutes idle. If that happens, just re-run this script.
SUMMARY
