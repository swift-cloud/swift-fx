#!/bin/sh
set -eu
if [ "$#" -ne 2 ]; then echo "usage: $0 <version> <checksum>" >&2; exit 1; fi
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
version=$1
checksum=$2
python3 - "$root/Package.swift" "$version" "$checksum" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); version=sys.argv[2]; checksum=sys.argv[3]
s=p.read_text()
s=re.sub(r'releases/download/[^/]+/FXCore', f'releases/download/{version}/FXCore', s)
s=re.sub(r'checksum: "[0-9a-f]{64}"', f'checksum: "{checksum}"', s)
p.write_text(s)
PY
