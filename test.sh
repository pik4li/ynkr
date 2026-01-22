#!/usr/bin/env -S bash --norc

cd "${0%/*}" >/dev/null 2>&1 || : # cd's into the right dir for sourcing..

. lib/logging.sh
. lib/parser.sh

sanitize-metadata & # sub process for managing sanitization.. Will get addet in the future.
