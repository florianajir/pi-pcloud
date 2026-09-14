#!/bin/sh
# Regenerate homepage's favicon set from the pi-pcloud mark (docs/assets/logo.png).
#
# Why the rasters exist at all: homepage's `favicon:` setting only takes effect
# after client-side hydration (it reads from SettingsProvider, see src/pages/_app.jsx),
# so the server-rendered HTML still points at the stock /favicon-*.png, /homepage.ico
# and /apple-touch-icon.png. Browsers latch onto those first and frequently never
# re-read the swapped <link>. compose/compose-monitoring.yaml bind-mounts the files generated here over
# the stock ones in /app/public so the mark is correct from the first byte.
#
# Only needs re-running when docs/assets/logo.png changes.
set -eu

cd "$(dirname "$0")/.."
ICONS=config/homepage/icons
SRC=docs/assets/logo.png

command -v convert >/dev/null || { echo "missing convert (imagemagick)" >&2; exit 1; }

# Below ~48px the mark's strokes land between pixels and Lanczos alone leaves the
# navy house muddy against the white cloud interior, so small frames get sharpened.
render() {
  size=$1; dest=$2
  set -- "$SRC" -filter Lanczos -resize "${size}x${size}"
  if [ "$size" -le 48 ]; then
    set -- "$@" -unsharp 0x0.5+0.5+0.02
  fi
  convert "$@" -background none -gravity center -extent "${size}x${size}" \
          -strip -define png:compression-level=9 "$ICONS/$dest"
  echo "  $dest (${size}px)"
}

echo "Rendering from $SRC:"
render 16 favicon-16x16.png
render 32 favicon-32x32.png
render 192 android-chrome-192x192.png
render 512 android-chrome-512x512.png

# Also served as /icons/logo.png, which compose/compose-monitoring.yaml points homepage's own tile at.
cp "$ICONS/android-chrome-512x512.png" "$ICONS/logo.png"
echo "  logo.png"

# Apple composites the touch icon onto black where it is transparent, so this one
# frame is flattened onto the mark's own off-white instead of left with an alpha.
convert "$SRC" -filter Lanczos -resize 180x180 -background '#f7f9fa' \
        -gravity center -extent 180x180 -flatten \
        -strip -define png:compression-level=9 "$ICONS/apple-touch-icon.png"
echo "  apple-touch-icon.png (180px, flattened)"

# Multi-resolution .ico. Each frame is resampled from the 1024px master rather
# than from one shared raster, so none of them is a blurry up- or downscale.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for size in 16 32 48; do
  convert "$SRC" -filter Lanczos -resize "${size}x${size}" -unsharp 0x0.5+0.5+0.02 \
          -background none -gravity center -extent "${size}x${size}" "$tmp/$size.png"
done
convert "$tmp/48.png" "$tmp/32.png" "$tmp/16.png" "$ICONS/homepage.ico"
echo "  homepage.ico (48,32,16)"

# /favicon.ico is not in homepage's HTML, but browsers request it as a last resort
# (and would 404 here), so cover that path too.
cp "$ICONS/homepage.ico" "$ICONS/favicon.ico"
echo "  favicon.ico"

cp "$ICONS/logo-mask.svg" "$ICONS/safari-pinned-tab.svg"
echo "  safari-pinned-tab.svg"
