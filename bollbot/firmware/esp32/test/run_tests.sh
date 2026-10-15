#!/usr/bin/env bash
# Run the firmware tests on a PC (Linux / macOS / WSL / Git Bash with g++).
#   1. core logic tests (safety gate, spray controller, servo planner)
#   2. the real sketch (bollbot_fw.ino) against stand-in libraries
set -euo pipefail
cd "$(dirname "$0")"
BUILD=build
mkdir -p "$BUILD"

AJ_VER=7.2.1
if [ ! -f "$BUILD/ArduinoJson.h" ]; then
  echo "downloading ArduinoJson $AJ_VER (header only)..."
  curl -sSL -o "$BUILD/ArduinoJson.h" \
    "https://github.com/bblanchon/ArduinoJson/releases/download/v$AJ_VER/ArduinoJson-v$AJ_VER.h"
fi
# The sketch includes secrets.h; tests use the example values.
cp ../bollbot_fw/secrets.example.h "$BUILD/secrets.h"

FLAGS="-std=c++17 -Wall -Wextra -O0 -g"
if g++ -fsanitize=address,undefined -x c++ -o /dev/null - <<<'int main(){}' 2>/dev/null; then
  FLAGS="$FLAGS -fsanitize=address,undefined"
fi

g++ $FLAGS -Werror -I../bollbot_fw test_core.cpp ../bollbot_fw/core.cpp -o "$BUILD/test_core"
"$BUILD/test_core"
g++ $FLAGS -Istubs -I"$BUILD" -I../bollbot_fw test_sketch.cpp ../bollbot_fw/core.cpp -o "$BUILD/test_sketch"
"$BUILD/test_sketch"
echo "firmware tests OK"
