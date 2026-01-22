#!/usr/bin/env -S bash --norc

cd "${0%/*}" >/dev/null 2>&1 || : # cd's into the right dir for sourcing..

. lib/logging.sh
. lib/parser.sh
