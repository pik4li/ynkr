#!/usr/bin/env bash
# MusicBrainz integration for enriching downloaded music files

# ---------- configuration ----------
declare -r MB_API_BASE="https://musicbrainz.org/ws/2"
declare -r MB_USER_AGENT="ynkr/1.0 (info@team-pieck.de)"
declare -r MB_RATE_LIMIT=1    # 1 request per second (MusicBrainz requirement)
declare -r MB_MAX_BATCH=5     # Process 5 files at a time
declare -i _MB_LAST_REQUEST=0 # Track last API call timestamp

# ---------- helpers ----------

_url_encode() {
  local string="$1"
  local encoded=""
  local i char
  for ((i = 0; i < ${#string}; i++)); do
    char="${string:i:1}"
    case "$char" in
    [a-zA-Z0-9.~_-]) encoded+="$char" ;;
    ' ') encoded+='+' ;;
    *) encoded+=$(printf '%%%02X' "'$char") ;;
    esac
  done
  printf '%s' "$encoded"
}

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

_mb_read_file_metadata() {
  local file="$1"
  local field="$2" # artist, album, title
  ffprobe -v quiet -show_entries format_tags="$field" \
    -of default=noprint_wrappers=1:nokey=1 "$file" 2>/dev/null
}

# ---------- rate limiting ----------

_mb_rate_limit() {
  local now
  now=$(date +%s)
  local diff=$((now - _MB_LAST_REQUEST))
  if ((diff < MB_RATE_LIMIT)); then
    local wait=$((MB_RATE_LIMIT - diff))
    log info "${ANSI[blue]}[mb:]${ANSI[nc]} Rate limiting - sleeping ${wait}s"
    sleep "$wait"
  fi
  _MB_LAST_REQUEST=$(date +%s)
}

# ---------- MusicBrainz API ----------

_mb_search() {
  local title="$1"
  local artist="${2:-}"
  local query

  if [[ -n "$artist" ]]; then
    # More specific search: artist AND recording
    query="artist:$(_url_encode "$artist")+AND+recording:$(_url_encode "$title")"
  else
    # Fallback to recording-only search
    query="recording:$(_url_encode "$title")"
  fi

  local url="${MB_API_BASE}/recording?query=${query}&fmt=json&limit=1"

  curl --silent --fail --max-time 10 --retry 2 \
    -H "User-Agent: ${MB_USER_AGENT}" \
    -H "Accept: application/json" \
    "$url"
}

_mb_extract_artist() {
  local json="$1"
  local artist
  artist=$(printf '%s' "$json" | jq -r '.recordings[0]["artist-credit"][0].name // empty')
  [[ -n "$artist" ]] && printf '%s' "$artist"
}

_mb_extract_album() {
  local json="$1"
  local album
  album=$(printf '%s' "$json" | jq -r '.recordings[0].releases[0].title // empty')
  [[ -n "$album" ]] && printf '%s' "$album"
}

# ---------- yt-dlp fallback ----------

_mb_ytdlp_fallback() {
  local yt_id="$1"
  log info "${ANSI[blue]}[mb:]${ANSI[nc]} Using yt-dlp fallback for ${ANSI[cyan]}${yt_id}${ANSI[nc]}"
  yt-dlp --dump-single-json --no-warnings "https://youtube.com/watch?v=${yt_id}" 2>/dev/null |
    jq -r '.channel // .uploader // "Unknown Artist"'
}

# ---------- file operations ----------

_mb_get_pending_files() {
  # Find files in DOWNLOADS that have 'downloaded' tag but not 'organized'
  local files=()
  local file yt_id tags

  for file in "$DOWNLOADS"/*; do
    [[ -f "$file" ]] || continue

    # Extract yt_id from filename (remove path and extension)
    yt_id=$(basename "$file")
    yt_id="${yt_id%.*}"

    # Check tags
    tags=$(db:get-song-tag "$yt_id" 2>/dev/null)
    if [[ "$tags" == *"downloaded"* && "$tags" != *"organized"* ]]; then
      files+=("$file")
    fi
  done

  printf '%s\n' "${files[@]}"
}

_mb_move_file() {
  local src="$1" dest_dir="$2" dest_name="$3"
  local ext="${src##*.}"
  local dest_path="${dest_dir}/${dest_name}.${ext}"

  # Create directory
  if ! mkdir -p "$dest_dir"; then
    log err "${ANSI[blue]}[mb:_move_file:]${ANSI[nc]} ${ANSI[red]}Failed to create directory: ${dest_dir}"
    return 1
  fi

  # Handle duplicates by appending number
  local counter=1
  while [[ -e "$dest_path" ]]; do
    dest_path="${dest_dir}/${dest_name} (${counter}).${ext}"
    ((counter++))
  done

  if mv "$src" "$dest_path"; then
    log info "${ANSI[blue]}[mb:]${ANSI[nc]} Moved to ${ANSI[cyan]}${dest_path}${ANSI[nc]}"
    printf '%s' "$dest_path"
    return 0
  else
    log err "${ANSI[blue]}[mb:]${ANSI[nc]} ${ANSI[red]}Failed to move${ANSI[nc]} ${src} -> ${dest_path}"
    return 1
  fi
}

# ---------- main processing ----------

_mb_process_file() {
  local file="$1"
  local yt_id artist album title file_artist file_album path

  # Extract yt_id from filename
  yt_id=$(basename "$file")
  yt_id="${yt_id%.*}"

  # Get title from database
  title=$(db:get-song-name "$yt_id")
  if [[ -z "$title" ]]; then
    log warn "${ANSI[blue]}[mb:]${ANSI[nc]} No title in DB for ${yt_id}"
    db:tag-song "$yt_id" "mb_error"
    return 1
  fi

  # Read embedded metadata from file (from yt-dlp --embed-metadata)
  file_artist=$(_mb_read_file_metadata "$file" "artist")
  file_album=$(_mb_read_file_metadata "$file" "album")

  log info "${ANSI[blue]}[mb:]${ANSI[nc]} Processing ${ANSI[cyan]}$title${ANSI[nc]} (file_artist=${ANSI[magenta]}$file_artist${ANSI[nc]})"

  # Rate limit before API call
  _mb_rate_limit

  # Query MusicBrainz with artist if available for better matching
  local json
  json=$(_mb_search "$title" "$file_artist")

  if [[ -n "$json" ]]; then
    artist=$(_mb_extract_artist "$json")
    album=$(_mb_extract_album "$json")
  fi

  # Fallback chain:
  # 1. MB results -> use MB data
  # 2. No MB but file metadata -> use file metadata
  # 3. Nothing -> yt-dlp fallback
  if [[ -z "$artist" ]]; then
    if [[ -n "$file_artist" ]]; then
      log info "${ANSI[blue]}[mb:]${ANSI[nc]} Using file metadata artist: ${ANSI[cyan]}$file_artist${ANSI[nc]}"
      artist="$file_artist"
      album="${file_album:-singles}"
      db:tag-song "$yt_id" "mb_file_fallback"
    else
      log info "${ANSI[blue]}[mb:]${ANSI[nc]} ${ANSI[yellow]}No MB results, using yt-dlp fallback${ANSI[nc]}"
      artist=$(_mb_ytdlp_fallback "$yt_id")
      db:tag-song "$yt_id" "mb_fallback"
    fi
  fi

  # Use file album if MB didn't return one but file has it
  if [[ -z "$album" && -n "$file_album" ]]; then
    album="$file_album"
  fi

  # Default to "Unknown Artist" if still empty
  [[ -z "$artist" ]] && artist="Unknown Artist"

  # Use "singles" if no album found
  [[ -z "$album" ]] && album="singles"

  # Sanitize all components
  artist=$(_sanitize_filename "$artist")
  album=$(_sanitize_filename "$album")
  local safe_title
  safe_title=$(_sanitize_filename "$title")

  # Build destination path
  local dest_dir="${MUSIC_DIR}/${artist}/${album}"

  # Move file
  path=$(_mb_move_file "$file" "$dest_dir" "$safe_title")
  if [[ $? -ne 0 ]]; then
    db:tag-song "$yt_id" "move_error"
    return 1
  fi

  # Update database
  db:tag-song "$yt_id" "organized"
  db:update-song-metadata "$yt_id" "$artist" "$album" "$path"

  log info "${ANSI[blue]}[mb:]${ANSI[nc]} ${ANSI[green]}Organized${ANSI[nc]} ${ANSI[cyan]}$title${ANSI[nc]} -> ${ANSI[magenta]}${artist}/${album}${ANSI[nc]}"
  return 0
}

mb:process() {
  log info "${ANSI[blue]}[mb:]${ANSI[nc]} ${ANSI[green]}Starting MusicBrainz processing${ANSI[nc]}"

  # Ensure MUSIC_DIR exists
  [[ -d "$MUSIC_DIR" ]] || mkdir -p "$MUSIC_DIR"

  # Run database migration
  db:migrate-mb

  # Get pending files
  local files=()
  while IFS= read -r file; do
    [[ -n "$file" ]] && files+=("$file")
  done < <(_mb_get_pending_files)

  local count=${#files[@]}
  if ((count == 0)); then
    log info "${ANSI[blue]}[mb:]${ANSI[nc]} No files to process"
    return 0
  fi

  log info "${ANSI[blue]}[mb:]${ANSI[nc]} Found ${ANSI[cyan]}${count}${ANSI[nc]} files to process"

  # Process up to MB_MAX_BATCH files
  local processed=0
  for file in "${files[@]}"; do
    ((processed >= MB_MAX_BATCH)) && break
    _mb_process_file "$file" && ((processed++))
  done

  log info "${ANSI[blue]}[mb:]${ANSI[nc]} ${ANSI[green]}Processed${ANSI[nc]} ${ANSI[cyan]}${processed}/${count}${ANSI[nc]} files"
}
