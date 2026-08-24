#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cp "$root/Package.local.swift" "$root/Package.swift"
