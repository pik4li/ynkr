#!/usr/bin/env bash
cd "${0%/*}" >/dev/null 2>&1 || : # cd's into the right dir for sourcing..

. lib/env

. lib/log.sh
. lib/ynkr.sh
. lib/db.sh
. lib/acoustid.sh
. lib/musicbrainz.sh
. lib/jellyfin.sh

ynkr:meta
