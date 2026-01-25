#!/usr/bin/env bash
cd "${0%/*}" >/dev/null 2>&1 || : # cd's into the right dir for sourcing..

. lib/env

. lib/log.sh
. lib/ynkr.sh
. lib/db.sh
. lib/musicbrainz.sh
. lib/jellyfin.sh

[[ -n "$ACOUSTID_KEY" ]] || {
  log error "YOU DO NOT HAVE \$ACOUSTID_API_KEY SET!"
  log error "SET IT IN THE 'docker-compose.yml' FILE!"
  exit 1
}

prepare() {
  ynkr:parse-playlist-file            # parses the playlist file and gets the variables right
  ynkr:get-playlist-ids YNKR_PLAYLIST # replaces the urls with the actual playlist ids

  local name

  db:init
  for name in "${!YNKR_PLAYLIST[@]}"; do
    local id=${YNKR_PLAYLIST[$name]}
    [[ -n "$name" && -n "$id" ]] || continue

    db:add-playlist "$name" "$id" # add playlist to the database

    local INFO
    INFO=$(ynkr:get-playlist-info "$id")

    local songs=() ids=() line
    while read -r line; do
      ids+=("$line")
    done <<<"$(ynkr:get-song-ids "$INFO")"

    while read -r line; do
      songs+=("$line")
    done <<<"$(ynkr:get-song-titles "$INFO")"

    local len=${#songs[@]}
    local playlist_yt_id
    playlist_yt_id=$(printf "%s\n" "$INFO" | jq -r '.id')

    for ((j = 0; j < len; j++)); do
      local song_name=${songs[j]}
      local song_id=${ids[j]}

      local song_tag=$(db:get-song-tag "$song_id")

      case "$song_tag" in
      *processed* | *downloaded*) ;;
      *)
        db:add-song "${song_name}" "${song_id}" "$playlist_yt_id"
        ;;
      esac

      # Only tag as pending if not already processed
      if ! db:is-song-processed "$song_id"; then
        db:tag-song "${song_id}" "pending"
      fi

      sleep .005
    done
  done
}
download() {
  # First, clean up any songs with empty names (unavailable videos)
  db:cleanup-unavailable

  local songs=()
  songs=($(db:get-pending))

  log info "${ANSI[green]}[download]${ANSI[nc]} Staged ${ANSI[magenta]}${#songs[@]}${ANSI[nc]} songs to download"

  local accum=1
  for id in "${songs[@]}"; do
    local name
    name="$(db:get-song-name "$id")"
    log info "${ANSI[green]}[download]${ANSI[nc]}(${ANSI[magenta]}$accum/${#songs[@]}${ANSI[nc]})${ANSI[nc]} name=${name};id=${id}"

    # Skip songs with empty names (unavailable videos)
    if [[ -z "$name" ]]; then
      log warn "${ANSI[yellow]}[download]${ANSI[nc]} Skipping ${id}: video unavailable (no title)"
      db:mark-failed "$id"
      ((accum++))
      continue
    fi

    if ynkr:song "$id" "$name"; then
      if [[ -f "$DOWNLOADS/$id.*" ]]; then
        log info "${ANSI[green]}[download-suceess]${ANSI[bold]} name=${name@Q};id=${id@Q}"
        db:mark-downloaded "$id"
      else
        log error "${ANSI[red]}[download-fail]${ANSI[bold]} name=${name@Q};id=${id@Q}"
        db:mark-failed "$id"

        YNKR_FAILED_DOWNLOADS[$id]="$name"
      fi
    fi

    ((accum++))
    sleep .005
  done
}

main() {
  while true; do
    prepare
    if $YNKR_DEBUG; then
      db:show >&2
    fi

    download

    $YNKR_DEBUG && tree "$MUSIC_DIR" >&2

    for key in "${!YNKR_FAILED_DOWNLOADS[@]}"; do
      local val=${YNKR_FAILED_DOWNLOADS[$key]}
      log error "${ANSI[red]}[FAILED-DOWNLOAD]${ANSI[nc]}${ANSI[bold]}${key}:${val}"
    done

    log info "${ANSI[yellow]}YNKR - Done"
    log warn "${ANSI[yellow]}Sleeping for the next ${ANSI[red]}$SLEEP${ANSI[yellow]} seconds"

    sleep $SLEEP
  done
}

main

# Trap signals for graceful shutdown
trap 'log info "Shutting down..."; exit 0' SIGTERM SIGINT
