#!/usr/bin/env bash
ynkr:parse-playlist-file() {
  local file="/app/playlists"
  local count=0
  [[ -n "$file" && -f "$file" ]] || {
    log error "$file - was not found!"
    exit 1
  }

  # IFS="="
  while read -r url; do
    ((count++))
    url=${url% }
    url=${url# }
    name=$(ynkr:get-playlist-info "$url" | jq -r '.title')
    [[ -n "$name" ]] || name="unknown"

    YNKR_PLAYLIST[$name]="$url"
    log info "${ANSI[magenta]}ynkr:parse-playlist-file:${ANSI[nc]} name=${ANSI[cyan]}$name${ANSI[nc]}; url=${ANSI[green]}${ANSI[nc]}"
  done <"$file"
}

# parses the id from the playlist url
ynkr:get-playlist-ids() {
  local -n PLAYLIST=$1 # Assosiative array (YNKR_PLAYLIST)
  local idx

  for idx in "${!PLAYLIST[@]}"; do
    local id
    local target="${PLAYLIST[$idx]}"

    if [[ "$target" =~ (\?list=.*\&) ]]; then
      id=${BASH_REMATCH[0]%&}
      id=${id#\?list=}
    fi

    # overwrite the url with the id in the array
    PLAYLIST[$idx]=$id
  done
}

ynkr:get-playlist-info() {
  local PID=$1 # playlist id
  local yt_args=() ytcmd
  yt_args=(
    "--flat-playlist"
    "--dump-single-json"
    "--no-warnings"
    "$PID"
  )
  ytcmd="yt-dlp"

  $ytcmd "${yt_args[@]}"
}

ynkr:get-song-titles() {
  local info=$1
  printf "%s" "$info" | jq -r '.entries[].title'
}

ynkr:get-song-ids() {
  local info=$1
  printf "%s" "$info" | jq -r '.entries[].id'
}

ynkr:song() {
  # download song and get sanitized names and artists..
  local yid=$1
  local name=$2

  [[ -n "$yid" ]] || return 1
  local url="https://youtube.com/watch?v=$yid"

  log info "${ANSI[red]}:YT-DLP:${ANSI[nc]}${ANSI[bold]} Downloading: ${ANSI[cyan]}$name${ANSI[nc]} - ${ANSI[magenta]}$yid${ANSI[nc]}"

  local cmd="yt-dlp"
  local args=()
  args=(
    "--extract-audio"
    "--paths=$DOWNLOADS/"
    "--output=$yid"
    "--download-archive=$YT_ARCHIVE"
    "--embed-thumbnail"
    "--embed-metadata"
    "--audio-quality=0"
    "--concurrent-fragments=3"
    "--retries=5"
    "--progress" "--newline"
    "--color=always"
    "--abort-on-error"
    "$url"
  )

  $cmd "${args[@]}"
}

# should process metadata - gets put in background by main ynkr task.
ynkr:meta() {
  while true; do
    local tmp=()
    mapfile tmp < <(ls "$DOWNLOADS/" 2>/dev/null)
    ((${#tmp[@]} > 0)) || {
      sleep 10
      continue
    }

    local files=()
    for f in "${tmp[@]}"; do
      files+=("${f%.*}")
    done

    log info "${ANSI[magenta]}ynkr:meta:${ANSI[nc]} Found ${ANSI[green]}${#files[@]}${ANSI[nc]} files to process"

    # Process downloaded files with MusicBrainz
    mb:process

    # Sleep before next iteration
    for t in {30..0}; do
      sleep 1

      ((t == 30 || t == 20 || t == 10 || t < 6)) &&
        log info "${ANSI[magenta]}ynkr:meta:${ANSI[nc]} Next processing in: ${ANSI[cyan]}${t}"
    done
  done
}
