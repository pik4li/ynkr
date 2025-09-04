#!/usr/bin/env bash
# runs the import.py script with pip and installs all dependencies for the
# project. also allows for argument passthough. (eg. import.py --debug)
import=/app/import.py
venv=/app/venv/bin/activate
req=/app/requirements.txt

case "$1" in
init)
  # checks for the venv, if its not there, create it
  if [ ! -e "$venv" ]; then
    python3 -m venv /app/venv
  fi

  # sourcing venv
  . "$venv"

  # upgrading pip to the latest version
  pip install --upgrade pip
  sleep 0.3

  # installing requirements
  pip install -r $req

  exit 0
  ;;
esac

# checks for the venv, if its not there, create it
if [ ! -e "$venv" ]; then
  python3 -m venv /app/venv
fi

# sourcing venv
. "$venv"

# upgrading pip to the latest version
pip install --upgrade pip
sleep 0.3

# installing requirements
pip install -r $req

# starting the script
if [ -z "$1" ]; then
  python $import /downloads/ /music/
else
  python $import "$@" /downloads/ /music/
fi
