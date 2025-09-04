#!/usr/bin/env bash

# ─< Check if the given command exists silently >─────────────────────────────────────────
command_exists() {
  command -v "$@" >/dev/null 2>&1
}

if ! command_exists docker; then
  echo "Docker is not installed! Exiting now!!"
  return 69
fi

if [ ! -f ./Dockerfile ]; then
  return 69
fi

docker build "$@" -t "${IMAGE:-git.k4li.de/docker/ynkr}:${TAG:-latest}" .
