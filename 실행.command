#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$PROJECT_DIR/scripts/build.sh"
open "$PROJECT_DIR/build/바탕화면 강아지.app"
