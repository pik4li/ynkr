#!/usr/bin/env -S bash --norc

cd "${0%/*}" || : # cd's into the right dir for sourcing..

source lib/logging.sh
source lib/parser.sh

get-pl-info klassik "https://www.youtube.com/playlist?list=PLzXB9N9Lp6mUieUdNXLqgi5zAfTO2ExF7"

echo "$klassik" >testinput

# echo "TITLE: " $(pl-title "$klassik")
data="$(jq -r '[.entries[] | .title, .url]' <<<"$klassik")"
data=${data#[}
data=${data%]}

printf "· %s\n" "${data}"

# printf "· <%s>\n" "$(pl-songs "$klassik")"
