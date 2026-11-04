#!/usr/bin/env bash
# Regression: importing the default local ISO must update every install reference.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DEV_ROOT="$WORK/dev-root"
SRC_DIR="$WORK/build-artifacts"
VERSION="test-new"
ISO="harvester-$VERSION-amd64.iso"

mkdir -p "$DEV_ROOT/scripts" "$DEV_ROOT/artifacts/isos/harvester-$VERSION" "$SRC_DIR" "$WORK/bin"
cp "$REPO_ROOT/scripts/use-local-iso.sh" "$DEV_ROOT/scripts/"
cp "$REPO_ROOT/artifacts/select-install-iso.sh" "$DEV_ROOT/artifacts/"

cat >"$DEV_ROOT/config.yaml" <<EOF
artifact_server_url: http://127.0.0.1:8787
harvester_version: old
harvester_iso_url: http://old/iso
harvester_kernel_url: http://old/kernel
harvester_ramdisk_url: http://old/initrd
harvester_rootfs_url: http://old/rootfs
iso_boot:
  file: /old/install.iso
EOF

for suffix in amd64.iso amd64-net-install.iso amd64.sha512 initrd-amd64 rootfs-amd64.squashfs vmlinuz-amd64; do
  printf 'new %s\n' "$suffix" >"$SRC_DIR/harvester-$VERSION-$suffix"
done
printf 'old ISO\n' >"$DEV_ROOT/artifacts/isos/harvester-$VERSION/$ISO"
chmod 0444 "$DEV_ROOT/artifacts/isos/harvester-$VERSION/$ISO"

cat >"$WORK/bin/mv" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ "$arg" == -* && "$arg" == *f* ]] && exec /bin/mv "$@"
done
echo 'expected mv to force replacement' >&2
exit 1
EOF
chmod +x "$WORK/bin/mv"

OUTPUT=$(printf '\n' | PATH="$WORK/bin:$PATH" "$DEV_ROOT/scripts/use-local-iso.sh" "$SRC_DIR" 2>&1)

grep -Fq "Selected version: harvester-$VERSION" <<<"$OUTPUT"
! grep -Fq 'replace ' <<<"$OUTPUT"
grep -Fxq "harvester_version: harvester-$VERSION" "$DEV_ROOT/config.yaml"
grep -Fxq "harvester_iso_url: http://127.0.0.1:8787/isos/harvester-$VERSION/harvester-$VERSION-amd64.iso" "$DEV_ROOT/config.yaml"
grep -Fxq "harvester_kernel_url: http://127.0.0.1:8787/isos/harvester-$VERSION/harvester-$VERSION-vmlinuz-amd64" "$DEV_ROOT/config.yaml"
grep -Fxq "harvester_ramdisk_url: http://127.0.0.1:8787/isos/harvester-$VERSION/harvester-$VERSION-initrd-amd64" "$DEV_ROOT/config.yaml"
grep -Fxq "harvester_rootfs_url: http://127.0.0.1:8787/isos/harvester-$VERSION/harvester-$VERSION-rootfs-amd64.squashfs" "$DEV_ROOT/config.yaml"
grep -Fxq "  file: \"$DEV_ROOT/artifacts/isos/harvester-$VERSION/harvester-$VERSION-amd64.iso\"" "$DEV_ROOT/config.yaml"
grep -Fxq 'new amd64.iso' "$DEV_ROOT/artifacts/isos/harvester-$VERSION/$ISO"

echo 'use-local-iso test: PASS'
