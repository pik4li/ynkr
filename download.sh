#!/usr/bin/env bash
DEBUG=false
USE_OPENAI=false
USE_OLLAMA=false

# set -eo pipefail
set -a
source /app/.env
set +a

# ─< ANSI color codes >───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
LIGHT_GREEN='\033[0;92m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ─< Path-Configuration >──────────────────────────────────────────────────────────────────────
OUTPUT_BASE="/downloads"
ARCHIVE_BASE="/archives"
PLAYLISTS_FILE="/app/playlists"

# ─< Env-Configuration >──────────────────────────────────────────────────────────────────────
MAX_RETRIES=2
RETRY_DELAY=15

# ─< Functions >──────────────────────────────────────────────────────────────────────────
echo_info() {
  printf "${BOLD}${CYAN}==> INFO:%s${NC}\n" " ${1}"
}

echo_success() {
  printf "${BOLD}${LIGHT_GREEN}==> SUCCESS:%s${NC}\n" " ${1}"
}

echo_error() {
  printf "${BOLD}${RED}==> ERROR:%s${NC}\n" " ${1}" >&2
}

echo_warning() {
  printf "${BOLD}${YELLOW}==> WARNING:%s${NC}\n" " ${1}"
}

sanitize_name() {
  local name="${1}"
  # Remove all non-alphanumeric characters except underscores and dashes
  echo "${name}" | tr -d "'" | tr -d '"' | tr -d " "
}

# ─< Main Script >────────────────────────────────────────────────────────────────────────
echo_info "Initializing downloader"
echo_info "Sleeping for network initialization"
for i in {10..1}; do
  echo "Waiting ${i} seconds..."
  sleep 1
done

# Create directories if they don't exist
mkdir -p "${OUTPUT_BASE}" "${ARCHIVE_BASE}"

# Get public IP
public_ip=$(curl -sf ifconfig.me || echo "unknown")
echo_warning "Public IP: ${public_ip}"

# Read playlists into array
mapfile -t playlists <"${PLAYLISTS_FILE}"

total_playlists=${#playlists[@]}
success_count=0
failure_count=0

echo_info "Processing ${total_playlists} playlists"

for ((i = 0; i < ${#playlists[@]}; i++)); do
  line_number=$((i + 1))
  line="${playlists[$i]}"

  # Skip empty lines and comments
  [[ -z "${line}" ]] && continue
  [[ "${line}" =~ ^# ]] && continue

  # Split into name and URL
  if [[ "${line}" =~ ^([^=]+)\ =\ (.*)$ ]]; then
    original_name="${BASH_REMATCH[1]}"
    url="${BASH_REMATCH[2]}"
  else
    echo_error "Malformed line ${line_number}: ${line}"
    ((failure_count++))
    continue
  fi

  # Sanitize name
  name=$(sanitize_name "${original_name}")
  echo_info "Processing playlist ${line_number}/${total_playlists}: ${original_name}"

  output_dir="${OUTPUT_BASE}/${name}"
  archive_file="${ARCHIVE_BASE}/${name}.txt"

  mkdir -p "${output_dir}"

  # Retry logic
  retry_count=0
  while [[ $retry_count -le $MAX_RETRIES ]]; do
    if yt-dlp \
      -x --audio-format best \
      --audio-quality 0 \
      --embed-thumbnail \
      --add-metadata \
      --download-archive "${archive_file}" \
      --concurrent-fragments 1 \
      --fragment-retries 3 \
      --skip-unavailable-fragments \
      --lazy-playlist \
      --color always \
      --no-abort-on-error \
      --no-break-on-existing \
      -o "${output_dir}/%(title)s.%(ext)s" \
      "${url}"; then
      echo_success "Completed: ${original_name}"
      ((success_count++))
      break
    else
      ((retry_count++))
      if [[ $retry_count -le $MAX_RETRIES ]]; then
        echo_warning "Failed download (attempt ${retry_count}/${MAX_RETRIES}), retrying in ${RETRY_DELAY}s..."
        sleep "${RETRY_DELAY}"
      else
        echo_error "Permanent failure: ${original_name}"
        ((failure_count++))
        break
      fi
    fi
  done
done

# Final report
echo_info "Download summary:"
echo_success "Successful downloads: ${success_count}"
[[ $failure_count -gt 0 ]] && echo_error "Failed downloads: ${failure_count}"
echo_info "Total processed: ${total_playlists}"

if $USE_OPENAI || $USE_OLLAMA; then
  echo_info "Starting ai processing.."
  if $DEBUG; then
    echo_warning "DEBUG=true | Debug log will get generated"
    bash /app/run-import.sh --debug
  else
    bash /app/run-import.sh
  fi
fi
