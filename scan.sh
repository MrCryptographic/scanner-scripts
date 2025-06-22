#!/bin/bash

# =======================
# Configurable defaults
# =======================
DEFAULT_TIMEOUT=3
DEFAULT_MAX_MB=100

# =======================
# Parse CLI Arguments
# =======================
SEARCH_STRING=""
TIMEOUT=$DEFAULT_TIMEOUT
MAX_MB=$DEFAULT_MAX_MB

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --maxsize) MAX_MB="$2"; shift 2 ;;
    *) [[ -z "$SEARCH_STRING" ]] && SEARCH_STRING="$1" || { echo "Unknown argument: $1"; exit 1; }; shift ;;
  esac
done

[[ -z "$SEARCH_STRING" ]] && { echo "Usage: $0 [--timeout N] [--maxsize MB] \"search string\""; exit 1; }

# =======================
# Setup temp files
# =======================
TMP_MATCHES=$(mktemp)
JSON_OUT="matches.json"
CSV_OUT="matches.csv"
TXT_OUT="matches.txt"

> "$JSON_OUT"
> "$CSV_OUT"
> "$TXT_OUT"

# CSV + JSON headers
echo "file,line,match" > "$CSV_OUT"
echo "[" > "$JSON_OUT"

MOUNTS=$(mount | grep "^/" | awk '{print $3}' | grep -Ev '^/(proc|sys|dev|run|tmp|var/tmp)')
FILE_LIST=$(mktemp)
TOTAL_FILES=0
SCANNED_FILES=0
SKIPPED_FILES=0
MATCHES_FOUND=0
MAX_BYTES=$((MAX_MB * 1024 * 1024))

# =======================
# Index files
# =======================
echo "🔍 Indexing files (excluding >${MAX_MB}MB)..."
for MOUNT in $MOUNTS; do
  find "$MOUNT" -type f -readable -size -"${MAX_MB}"M >> "$FILE_LIST" 2>/dev/null
done
TOTAL_FILES=$(wc -l < "$FILE_LIST")
[[ "$TOTAL_FILES" -eq 0 ]] && { echo "No suitable files found."; exit 1; }

# =======================
# Display progress bar
# =======================
print_progress() {
  local width=40
  local percent=$((SCANNED_FILES * 100 / TOTAL_FILES))
  local filled=$((width * percent / 100))
  local empty=$((width - filled))

  printf "\033c"  # Clear terminal
  printf "🔍 Searching for: \"%s\"\n" "$SEARCH_STRING"
  printf "Timeout per file: %ss | Max file size: %sMB\n" "$TIMEOUT" "$MAX_MB"
  printf "Progress: ["
  printf "%0.s#" $(seq 1 $filled)
  printf "%0.s." $(seq 1 $empty)
  printf "] %s%%\n" "$percent"
  printf "Scanned: %s / %s | Skipped: %s | Matches: %s\n\n" "$SCANNED_FILES" "$TOTAL_FILES" "$SKIPPED_FILES" "$MATCHES_FOUND"
  tail -n 10 "$TXT_OUT"
}

# =======================
# Main loop
# =======================
FIRST_JSON=1
while IFS= read -r FILE; do
  ((SCANNED_FILES++))

  FILE_SIZE=$(stat -c%s "$FILE" 2>/dev/null)
  [[ "$FILE_SIZE" -gt "$MAX_BYTES" ]] && { ((SKIPPED_FILES++)); print_progress; continue; }

  # Run grep with timeout
  MATCHES=$(timeout "$TIMEOUT" grep -I -n -H -s -- "$SEARCH_STRING" "$FILE")
  EXIT_CODE=$?

  if [[ "$EXIT_CODE" -eq 124 ]]; then
    ((SKIPPED_FILES++))
  elif [[ "$EXIT_CODE" -eq 0 ]]; then
    while IFS= read -r LINE; do
      FILE_PATH=$(cut -d: -f1 <<< "$LINE")
      LINE_NUM=$(cut -d: -f2 <<< "$LINE")
      MATCH_TEXT=$(cut -d: -f3- <<< "$LINE" | sed 's/"/\\"/g')

      echo "$LINE" >> "$TXT_OUT"
      echo "\"$FILE_PATH\",$LINE_NUM,\"$MATCH_TEXT\"" >> "$CSV_OUT"

      [[ $FIRST_JSON -eq 0 ]] && echo "," >> "$JSON_OUT"
      echo "  {\"file\": \"${FILE_PATH//\"/\\\"}\", \"line\": $LINE_NUM, \"match\": \"${MATCH_TEXT}\"}" >> "$JSON_OUT"
      FIRST_JSON=0
      ((MATCHES_FOUND++))
    done <<< "$MATCHES"
  fi

  print_progress
done < "$FILE_LIST"

# Finalize JSON
echo "]" >> "$JSON_OUT"

# Final display
print_progress
echo -e "\n✅ Done."
echo "📁 Text Matches: $TXT_OUT"
echo "📁 CSV Output:   $CSV_OUT"
echo "📁 JSON Output:  $JSON_OUT"
