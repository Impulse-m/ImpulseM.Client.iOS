#!/bin/bash
# Generates the iOS icon and logo tree from the brand SVG sources.
#
# Usage: generate_ios_icons.sh [SVG_DIR] [OUT_DIR]
#   SVG_DIR  directory holding the sources named in ios_icon_manifest.txt
#            (default: build-system/icons/source next to this script)
#   OUT_DIR  root that the manifest output paths are written under
#            (default: the repository root)
#
# Needs macOS: qlmanage renders the SVG sources and sips resizes, flattens
# and writes PDF. Each manifest line is "source|output path|size", where size
# is "WxH" in pixels, "Npt" for a 24 pt style glyph rendered at three times
# its point size, or "svg" to copy the source unchanged.

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "generate_ios_icons.sh needs macOS (sips and qlmanage)." >&2
    exit 1
fi

scriptDir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repoRoot="$(cd "${scriptDir}/../.." && pwd)"
svgDir="${1:-${scriptDir}/source}"
outDir="${2:-${repoRoot}}"
manifest="${scriptDir}/ios_icon_manifest.txt"
workDir="$(mktemp -d)"

trap 'rm -rf "${workDir}"' EXIT

# Renders an SVG source to a 1024 px PNG and prints its path. Icon set outputs
# must be opaque, so those are flattened through JPEG; glyphs keep alpha.
renderMaster() {
    local svgName="$1"
    local flatten="$2"
    local base="${svgName%.svg}"
    local rawDir="${workDir}/raw-${base}-${flatten}"
    local rendered
    local result="${workDir}/master-${base}-${flatten}.png"

    mkdir -p "${rawDir}"
    qlmanage -t -s 1024 -o "${rawDir}" "${svgDir}/${svgName}" > /dev/null
    rendered="$(ls "${rawDir}"/*.png | head -n 1)"
    if [[ "${flatten}" == "1" ]]; then
        sips -s format jpeg "${rendered}" --out "${workDir}/flat-${base}.jpg" > /dev/null
        sips -s format png "${workDir}/flat-${base}.jpg" --out "${result}" > /dev/null
    else
        cp "${rendered}" "${result}"
    fi
    echo "${result}"
}

while IFS='|' read -r sourceName outputPath sizeSpec <&3; do
    if [[ -z "${sourceName}" ]]; then
        continue
    fi
    if [[ ! -f "${svgDir}/${sourceName}" ]]; then
        echo "Missing source: ${svgDir}/${sourceName}" >&2
        exit 1
    fi

    destination="${outDir}/${outputPath}"
    mkdir -p "$(dirname "${destination}")"

    if [[ "${sizeSpec}" == "svg" ]]; then
        cp "${svgDir}/${sourceName}" "${destination}"
        continue
    fi

    flatten="0"
    case "${outputPath}" in
        *.appiconset/*|*.alticon/*)
            flatten="1"
            ;;
    esac

    format="png"
    if [[ "${sizeSpec}" == *pt ]]; then
        format="pdf"
        points="${sizeSpec%pt}"
        width="$(( points * 3 ))"
        height="${width}"
    else
        width="${sizeSpec%x*}"
        height="${sizeSpec#*x}"
    fi

    master="$(renderMaster "${sourceName}" "${flatten}")"
    scaled="${workDir}/scaled-$(echo "${outputPath}" | tr -c 'A-Za-z0-9' '_').png"
    sips -z "${height}" "${width}" "${master}" --out "${scaled}" > /dev/null

    if [[ "${format}" == "pdf" ]]; then
        sips -s format pdf "${scaled}" --out "${destination}" > /dev/null
    else
        cp "${scaled}" "${destination}"
    fi
done 3< "${manifest}"

echo "Icons written under ${outDir}"
