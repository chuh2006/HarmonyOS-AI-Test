#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
DEVECO_STUDIO_HOME="${DEVECO_STUDIO_HOME:-/Applications/DevEco-Studio.app/Contents}"
export JAVA_HOME="$DEVECO_STUDIO_HOME/jbr/Contents/Home"
export DEVECO_SDK_HOME="$DEVECO_STUDIO_HOME/sdk"
export PATH="$DEVECO_STUDIO_HOME/tools/node/bin:$DEVECO_STUDIO_HOME/tools/ohpm/bin:$PATH"
exec "$DEVECO_STUDIO_HOME/tools/hvigor/bin/hvigorw" --mode module -p product=default -p module=entry@default assembleHap --no-daemon
