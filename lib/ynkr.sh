#!/usr/bin/env bash
ynkr:parse-playlist-file() {
  local file="${YNKR_PLAYLISTS:-./playlists}"
  [[ -n "$file" && -f "$file" ]] || {
    log error "${ANSI[cyan]}[ynkr:parse-playlist-file:] ${ANSI[red]}${file@Q} was not found!"
    exit 1
  }

  while read -r line; do
    # Strip comments (everything after #)
    local url="${line%%#*}"
    # Trim whitespace
    url="${url#"${url%%[![:space:]]*}"}" # leading
    url="${url%"${url##*[![:space:]]}"}" # trailing

    # Skip empty lines
    [[ -z "$url" ]] && continue

    name="$(ynkr:get-playlist-info "$url" | jq -r '.title')"
    [[ -n "$name" && "$name" != "null" ]] || name="unknown"

    YNKR_PLAYLIST[$name]="$url"
    log info "${ANSI[magenta]}[ynkr:parse-playlist-file:]${ANSI[nc]} name=${ANSI[cyan]}$name${ANSI[nc]}; url=$url${ANSI[green]}${ANSI[nc]}"
  done <"$file"

  if $YNKR_DEBUG; then
    declare -p YNKR_PLAYLIST
  fi
}

# parses the id from the playlist url
ynkr:get-playlist-ids() {
  local -n PLAYLIST=$1 # Associative array (YNKR_PLAYLIST)
  local idx

  for idx in "${!PLAYLIST[@]}"; do
    local id
    local target="${PLAYLIST[$idx]}"

    # Extract playlist ID from URL
    if [[ "$target" =~ list=([^&[:space:]]*) ]]; then
      id=${BASH_REMATCH[1]}
    fi

    [[ -n "$id" ]] || continue

    # Overwrite the url with the id in the array
    PLAYLIST[$idx]=$id

    if $YNKR_DEBUG; then
      log info "${ANSI[blue]}[ynkr:get-playlist-ids]${ANSI[nc]} Parsed playlist: ${ANSI[cyan]}$idx${ANSI[nc]} -> ${ANSI[magenta]}$id${ANSI[nc]}"
    fi
  done
}

ynkr:get-playlist-info() {
  local PID=$1 # playlist id
  local yt_args=() ytcmd
  yt_args=(
    "--flat-playlist"
    "--dump-single-json"
    "--no-warnings"
    "--yes-playlist"
    "$PID"
  )
  ytcmd="yt-dlp"

  $ytcmd "${yt_args[@]}"
}

ynkr:get-song-titles() {
  local info=$1
  # Filter out entries with null/empty titles (unavailable videos)
  printf "%s" "$info" | jq -r '.entries[] | select(.title != null and .title != "") | .title'
}

ynkr:get-song-ids() {
  local info=$1
  # Filter out entries with null/empty titles (unavailable videos)
  printf "%s" "$info" | jq -r '.entries[] | select(.title != null and .title != "") | .id'
}

ynkr:song() {
  # download song and get sanitized names and artists..
  local yid=$1
  local name=$2

  [[ -n "$yid" ]] || return 1
  local url="https://youtube.com/watch?v=$yid"

  local tag=$(db:get-song-tag "$yid")

  case "$tag" in
  *fail*)
    log info "${ANSI[magenta]}[:YT-DLP:]${ANSI[nc]}${ANSI[bold]} Skipping: ${ANSI[cyan]}name=${name@Q}${ANSI[nc]};${ANSI[magenta]}id=$yid${ANSI[nc]};tag=$tag"
    return
    ;;
  esac

  log info "${ANSI[magenta]}[:YT-DLP:]${ANSI[nc]}${ANSI[bold]} Downloading: ${ANSI[cyan]}${name@Q}${ANSI[nc]} - ${ANSI[magenta]}$yid${ANSI[nc]}"

  local cmd="yt-dlp"
  local args=()
  args=(
    "--extract-audio"
    "--output=$DOWNLOADS/$yid"
    "--download-archive=$YT_ARCHIVE"
    "--embed-thumbnail"
    "--embed-metadata"
    "--audio-quality=0"
    "--concurrent-fragments=3"
    "--quiet"
    "--progress" "--newline"
    "--color=always"
    "--retries=5"
    "$url"
  )

  if ! $cmd "${args[@]}"; then
    log info "${ANSI[magenta]}[ynkr:song:]${ANSI[nc]}${ANSI[cyan]} Trying again with '--extractor-args=youtube:player-client=default,mweb'"
    args+=("--extractor-args=youtube:player-client=default,mweb")
    if ! $cmd "${args[@]}"; then
      db:mark-failed "$yid"
    fi
  fi
}

# should process metadata - gets put in background by main ynkr task.
ynkr:meta() {
  while true; do
    local tmp=() t f
    mapfile tmp < <(find "$DOWNLOADS" -type f -not -name "*.db" 2>/dev/null)
    ((${#tmp[@]} > 0)) || {
      log warn "${ANSI[magenta]}[ynkr:meta:]${ANSI[nc]} No files to process.."
      for t in {10..0}; do
        sleep 1

        ((t == 10 || t == 3 || t == 1)) &&
          log warn "${ANSI[magenta]}[ynkr:meta:]${ANSI[nc]}Next filecheck in: ${ANSI[cyan]}${t}"
      done
      continue
    }

    local files=()
    for f in "${tmp[@]}"; do
      files+=("${f%.*}")
    done

    log info "${ANSI[magenta]}[ynkr:meta:]${ANSI[nc]} Found ${ANSI[green]}${#files[@]}${ANSI[nc]} files to process"

    # Process downloaded files with AcoustID (primary metadata source)
    aid:process

    # Process downloaded files with MusicBrainz (fallback for AcoustID failures)
    mb:process

    # Tag organized files for Jellyfin compatibility
    jf:process

    # Sleep before next iteration
    for t in {30..0}; do
      sleep 1

      ((t == 30 || t == 20 || t == 10 || t < 6)) &&
        log info "${ANSI[magenta]}[ynkr:meta:]${ANSI[nc]} Next processing in: ${ANSI[cyan]}${t}"
    done
  done
}
