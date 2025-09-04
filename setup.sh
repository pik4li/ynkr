#!/usr/bin/env bash

command-exists() {
  command -v "$@" >/dev/null 2>&1
}

build-ynkr() {
  if command-exists docker; then
    docker build -t ynkr:latest . || {
      echo "You do not have docker installed on your system, or you might not be in the docker group."
      echo "Cannot continue build process!"
      exit 1
    }
  else
    echo "You do not have docker installed on your system"
    echo "Please install docker, and rerun this script"
    exit 1
  fi
}

check-dirs() {
  local dirs=(
    "archives"
    "db"
    "downloads"
    "music"
  )

  for dir in "${dirs[@]}"; do
    if [[ ! -e "${dir}" ]]; then
      mkdir -p "${dir}"
    fi
  done
}

# check and create directories
check-dirs
[[ ! -f ./db/music_imports.db ]] && touch ./db/music_imports.db # create database file

# build ynkr:latest or exit, if
build-ynkr

echo "Setup is done, created ${dirs[*]} and ./db/music_imports.db"
echo "Also the ynkr:latest container was build."
echo "Keep in mind, that you have to setup your playlists file, and your .env file"
echo "You can then run ynkr with 'docker compose up -d'"
