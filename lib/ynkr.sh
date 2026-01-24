#!/usr/bin/env bash
. /app/lib/db.sh
YT_ARCHIVE=/app/.cache/archive

[[ -d "$YT_ARCHIVE" ]] || mkdir -p "$YT_ARCHIVE"

ynkr:parse-playlist-file() {
  local file="/app/playlists"
  local count=0
  [[ -n "$file" && -f "$file" ]] || {
    log error "$file - was not found!"
    exit 1
  }

  IFS="="
  while read -r name url; do
    ((count++))
    name=${name% }
    name=${name# }

    url=${url% }
    url=${url# }

    YNKR_PLAYLISTS[$name]+=":$url:"
  done <"$file"
}

# parses the id from the playlist url
ynkr:get-playlist-ids() {
  local -n PLAYLIST=$1 # Assosiative array (YNKR_PLAYLISTS)
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

  log info "${ANSI[red]}:YT-DLP:${ANSI[nc]}${ANSI[bold]} Downloading: ${ANSI[CYAN]}$name${ANSI[nc]} - ${ANSI[magenta]}$yid${ANSI[nc]}"

  local cmd="yt-dlp"
  local args=()
  args=(
    "--extract-audio"
    "--paths=$DOWNLOADS/"
    "--output=$yid"
    "--embed-thumbnail"
    "--embed-metadata"
    "--audio-quality=0"
    "--concurrent-fragments=3"
    "--retries=5"
    "--download-archive=$YT_ARCHIVE.yt"
    "--print='%(colors.green)s▶%(colors.reset)s %(title)s\n%(colors.blue)s👤 %(uploader)s%(colors.reset)s | %(colors.magenta)s⏱ %(duration_string)s%(colors.reset)s | %(colors.cyan)s📺 %(resolution)s%(colors.reset)s | %(colors.yellow)s🎵 %(format_note)s%(colors.reset)s\n%(colors.gray)s%(webpage_url)s%(colors.reset)s\n'"
    "$url"
  )

  $cmd "${args[@]}"
}
