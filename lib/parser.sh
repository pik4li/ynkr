#!/usr/bin/env -S bash --norc

parse-file() {
  local file=$1
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

    log info "name: <$name> | url: <$url>"
  done <"$file"

  echo "Count: $count"
}

get-vars() {
  local -n playlists=$1

  # playlists=$()
}

get-pl-info() {
  local pl=$2
  local -n info=$1

  local YT_DLP_ARGS=()
  YT_DLP_ARGS=(
    "--flat-playlist"
    "--dump-single-json"
    "$pl"
  )

  [[ -n "$pl" ]] || return
  info=$(yt-dlp "${YT_DLP_ARGS[@]}")
}

pl-title() {
  local info=$1

  jq -r '.title' <<<"$info"
}

pl-songs() {
  local info=$1

  jq -r '.entries[]'
}
