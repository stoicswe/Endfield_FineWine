#!/bin/sh
# Stands in for CrossOver's Menu Helper. The launcher's command names the right CrossOver copy.
contents=$(cd "$(dirname "$0")/.." && pwd)
command=$(/usr/bin/plutil -extract CrossOverHelperCommand raw "$contents/Info.plist") || exit 1
eval "exec $command"
