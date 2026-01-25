#!/usr/bin/env bash
# AcoustID integration for primary metadata resolution

# ---------- helpers (copied from musicbrainz.sh for self-contained operation) ----------

_sanitize_filename() {
  local name="$1"
  # Remove characters not allowed in filenames: /\:*?"<>|
  name="${name//[\/\\:*?\"<>|]/}"
  # Replace multiple spaces with single space
  name="${name//  / }"
  # Trim leading/trailing whitespace
  name="${name# }"
  name="${name% }"
  # Truncate to 200 chars
  printf '%s' "${name:0:200}"
}

_aid_move_file() {
  local src="$1" dest_dir="$2" dest_name="$3"
  local ext="${src##*.}"
  local dest_path="${dest_dir}/${dest_name}.${ext}"

  # Create directory
  if ! mkdir -p "$dest_dir"; then
    log err "${ANSI[red]}[aid:_move_file:]${ANSI[nc]} ${ANSI[red]}Failed to create directory: ${dest_dir}"
    return 1
  fi

  # Handle duplicates by appending number
  local counter=1
  while [[ -e "$dest_path" ]]; do
    dest_path="${dest_dir}/${dest_name} (${counter}).${ext}"
    ((counter++))
  done

  if mv "$src" "$dest_path"; then
    log info "$LOG_AID Moved to ${ANSI[cyan]}${dest_path}${ANSI[nc]}"
    printf '%s' "$dest_path"
    return 0
  else
    log err "${ANSI[red]}[aid:_move_file:]${ANSI[nc]} ${ANSI[red]}Failed to move${ANSI[nc]} ${src} -> ${dest_path}"
    return 1
  fi
}

# ---------- configuration ----------
declare -r AID_URL="https://api.acoustid.org/v2/lookup?client=${ACOUSTID_KEY}&meta=recordings"
declare -r AID_CACHE="/app/db/.cache"
declare -r LOG_AID="${ANSI[red]}[ACOUSTIC-ID]${ANSI[nc]}"

# AcoustID minimum confidence score (0.0-1.0)
# declare -r ACOUSTID_MIN_SCORE="${ACOUSTID_MIN_SCORE:-0.8}"

# AcoustID rate limiting (3 requests per second recommended)
declare -r AID_RATE_LIMIT=1    # Conservative: 1 request per second
declare -i _AID_LAST_REQUEST=0 # Track last API call timestamp

[[ -d "$AID_CACHE" ]] || mkdir -p "$AID_CACHE"

aid:make-fingerprint() {
  local file=$1
  [[ -e "$file" ]] || {
    log error "$LOG_AID File to create hash for does not exist! :${ANSI[magenta]}$file"
    return
  }

  local f="$(basename $file)"
  local original=${f%.*}
  local dest=${AID_CACHE}/${original}.fp

  if [[ -e "$dest" ]]; then
    log error "$LOG_AID Cachefile already exists! :${ANSI[magenta]}${dest}"
    return
  fi

  log info "$LOG_AID Starting to get fingerprint for $file"
  if fpcalc -json "$file" >"$dest"; then
    [[ -e "$dest" ]]
  else
    return 1
  fi
}

aid:ask-aid() {
  local fp_file="$1"

  [[ -e "$fp_file" ]] || {
    log error "$LOG_AID Failed to ask aid about file that doesn't exist! :${ANSI[magenta]}$fp_file"
    return 1
  }

  local dur fp

  dur=$(jq -r .duration <"$fp_file")
  fp=$(jq -r .fingerprint <"$fp_file")

  local final="${AID_URL}&fingerprint=${fp}&duration=${dur%.*}"

  local info
  info=$(curl -s "$final")

  if $YNKR_DEBUG; then
    log info "$LOG_AID Testing-url: ${final@Q}"
  fi

  [[ -n "$info" ]] || {
    log error "$LOG_AID No output: ${final@Q}"
    return 1
  }

  printf "%s" "$info"
}

# ---------- rate limiting ----------

_aid_rate_limit() {
  local now
  now=$(date +%s)
  local diff=$((now - _AID_LAST_REQUEST))
  if ((diff < AID_RATE_LIMIT)); then
    local wait=$((AID_RATE_LIMIT - diff))
    log info "$LOG_AID Rate limiting - sleeping ${wait}s"
    sleep "$wait"
  fi
  _AID_LAST_REQUEST=$(date +%s)
}

# ---------- AcoustID processing ----------

aid:get-pending-files() {
  # Find files in DOWNLOADS that have 'downloaded' tag but not 'organized'
  # and not yet processed by AcoustID
  local files=()
  mapfile files < <(find "$DOWNLOADS" -type f -not -name "*.db" 2>/dev/null)
  ((${#files[@]} > 0)) || {
    log warn "${ANSI[magenta]}[ynkr:meta:]${ANSI[nc]} No files to process.."
    return
  }

  printf "%s\n" "${files[@]}"
}

aid:extract-metadata() {
  local json="$1"

  min_score=${ACOUSTID_MIN_SCORE:-0.85}

  [[ -n "$json" ]] || return 1

  # Get first result with sufficient score
  local score title artist artists
  score=$(jq -r '.results[0].score // empty' <<<"$json")

  # Check if score meets minimum threshold
  [[ -n "$score" ]] || return 1

  export LAST_SCORE=$score

  # Use bc for floating point comparison (shell arithmetic doesn't handle decimals)
  if (($(echo "$score >= $min_score" | bc -l))); then
    # Extract metadata
    title=$(jq -r '.results[0].recordings[0].title // empty' <<<"$json")
    artist=$(jq -r '.results[0].recordings[0].artists[0].name // empty' <<<"$json")

    # Extract all artists as semicolon-separated list for Jellyfin
    artists=$(jq -r '.results[0].recordings[0].artists | map(.name) | join("; ") // empty' <<<"$json")
    # Extract AcoustID recording ID for reference
    local acoustid_id
    acoustid_id=$(jq -r '.results[0].id // empty' <<<"$json")

    if [[ -n "$title" && -n "$artist" ]]; then
      printf '%s\t%s\t%s\t%s\t%s' "$title" "$artist" "$artists" "$score" "$acoustid_id"
      return 0
    fi
  else
    log warning "$LOG_AID Score: ${ASCI[magenta]}$score"
  fi

  return 1
}

aid:process-file() {
  local file="$1"
  local yt_id title artist artists album score path acoustid_id

  # Extract yt_id from filename
  yt_id=$(basename "$file")
  yt_id="${yt_id%.*}"

  # Get title from database
  title=$(db:get-song-name "$yt_id")
  if [[ -z "$title" ]]; then
    log warn "$LOG_AID No title in DB for ${yt_id}"
    db:tag-song "$yt_id" "aid_error"
    return 1
  fi

  log info "$LOG_AID Processing ${ANSI[cyan]}$title${ANSI[nc]} (${ANSI[magenta]}$yt_id${ANSI[nc]})"

  # Generate fingerprint
  local fp_file="${AID_CACHE}/${yt_id}.fp"
  if [[ ! -e "$fp_file" ]]; then
    aid:make-fingerprint "$file" || {
      log error "$LOG_AID Failed to create fingerprint for $yt_id"
      db:tag-song "$yt_id" "aid_error"
      return 1
    }
  fi

  # Rate limit before API call
  _aid_rate_limit

  # Query AcoustID
  local response metadata
  response=$(aid:ask-aid "$fp_file")

  if [[ $? -ne 0 || -z "$response" ]]; then
    log error "$LOG_AID API call failed for $yt_id"
    db:tag-song "$yt_id" "aid_error"
    return 1
  fi

  # Extract metadata
  metadata=$(aid:extract-metadata "$response" "$ACOUSTID_MIN_SCORE")
  if [[ $? -ne 0 ]]; then
    log info "$LOG_AID ${ANSI[yellow]}No high-confidence match for ${title} (score[$LAST_SCORE] < ${ACOUSTID_MIN_SCORE})${ANSI[nc]}"
    db:tag-song "$yt_id" "aid_fallback"
    return 1
  fi

  # Parse extracted metadata
  IFS=$'\t' read -r title artist artists score acoustid_id <<<"$metadata"

  log info "$LOG_AID ${ANSI[green]}Match found!${ANSI[nc]} score=${score}, ${ANSI[cyan]}${title}${ANSI[nc]} by ${ANSI[magenta]}${artist}${ANSI[nc]}"

  # Default album for AcoustID matches (singles)
  album="singles"

  # Sanitize components
  artist=$(_sanitize_filename "$artist")
  album=$(_sanitize_filename "$album")
  local safe_title
  safe_title=$(_sanitize_filename "$title")

  # Build destination path
  local dest_dir="${MUSIC_DIR}/${artist}/${album}"

  # Move file (using internal helper)
  path=$(_aid_move_file "$file" "$dest_dir" "$safe_title")
  if [[ $? -ne 0 ]]; then
    db:tag-song "$yt_id" "aid_move_error"
    return 1
  fi

  # Update database with AcoustID metadata
  db:tag-song "$yt_id" "aid_processed"
  db:tag-song "$yt_id" "organized" # Mark as organized for Jellyfin
  db:update-song-metadata "$yt_id" "$artist" "$album" "$path" "$artists"
  db:update-song-acoustid "$yt_id" "$acoustid_id" "acoustid" "$score"

  log info "$LOG_AID ${ANSI[green]}Organized via AcoustID${ANSI[nc]} ${ANSI[cyan]}$title${ANSI[nc]} -> ${ANSI[magenta]}${artist}/${album}${ANSI[nc]}"
  return 0
}

aid:process() {
  log info "$LOG_AID ${ANSI[green]}Starting AcoustID processing${ANSI[nc]}"

  # Ensure MUSIC_DIR exists
  [[ -d "$MUSIC_DIR" ]] || mkdir -p "$MUSIC_DIR"

  # Ensure cache directory exists
  [[ -d "$AID_CACHE" ]] || mkdir -p "$AID_CACHE"

  # Get pending files
  local files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(aid:get-pending-files)

  local count=${#files[@]}
  if ((count == 0)); then
    log info "$LOG_AID No files to process"
    return 0
  fi

  log info "$LOG_AID Found ${ANSI[cyan]}${count}${ANSI[nc]} files to process"

  # Process files (similar batch size to MusicBrainz)
  local processed=0
  local max_batch=5
  for file in "${files[@]}"; do
    ((processed >= max_batch)) && break
    aid:process-file "$file" && ((processed++))
  done

  log info "$LOG_AID ${ANSI[green]}Processed${ANSI[nc]} ${ANSI[cyan]}${processed}/${count}${ANSI[nc]} files"
}
