#!/bin/bash -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEV_ROOT="$SCRIPT_DIR/.."
ISOS_DIR="$DEV_ROOT/artifacts/isos"

SRC_DIR="${1:-$SCRIPT_DIR/../../harvester/dist/artifacts}"

if [ ! -d "$SRC_DIR" ]; then
  echo "ERROR: source dir not found: $SRC_DIR"
  exit 1
fi

mapfile -t ISOS < <(ls "$SRC_DIR"/harvester-*-amd64.iso 2>/dev/null | grep -v net-install)
if [ ${#ISOS[@]} -eq 0 ]; then
  echo "ERROR: no *-amd64.iso found in $SRC_DIR"
  exit 1
fi

echo "Available ISOs:"
for i in "${!ISOS[@]}"; do
  f="${ISOS[$i]}"
  BASENAME=$(basename "$f" "-amd64.iso")
  VERSION="${BASENAME#harvester-}"
  MTIME=$(stat -c "%y" "$f" | cut -d'.' -f1)
  echo "  $((i+1))) $VERSION  $MTIME"
done
echo ""
read -rp "Choose [1-${#ISOS[@]}]: " CHOICE

ISO_FILE="${ISOS[$((CHOICE-1))]}"
BASENAME=$(basename "$ISO_FILE" "-amd64.iso")
VERSION="${BASENAME#harvester-}"

DEST_DIR="$ISOS_DIR/$BASENAME"
echo ""
mkdir -p "$DEST_DIR"
mv -v "$SRC_DIR"/harvester-"$VERSION"-* "$DEST_DIR"/

# Find the index in select-install-iso.sh's listing (sorted by glob)
INDEX=1
for dir in "$ISOS_DIR"/*/; do
  [ "$(basename "$dir")" = "$BASENAME" ] && break
  ((INDEX++))
done

"$DEV_ROOT/artifacts/select-install-iso.sh" "$INDEX"
