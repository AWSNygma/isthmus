#!/usr/bin/env bash
# End-to-end test: install an engine into a throwaway ISTHMUS_HOME, create a
# bottle, and run every Windows probe through the real `isthmus` launch path
# on each graphics backend. Needs an Apple silicon Mac with a GPU.
#
#   tests/integration/run.sh <engine.tar.xz> [path/to/isthmus]
#
# Prints a summary table and exits non-zero if any required probe fails.
set -uo pipefail
cd "$(dirname "$0")/../.."
ENGINE="${1:?usage: run.sh <engine.tar.xz> [isthmus]}"
CLI="${2:-.build/debug/isthmus}"
PROBES=tests/winprobes/build
[[ -x "$CLI" ]] || swift build --product isthmus
[[ -f "$PROBES/d3d11_probe.exe" ]] || make -C tests/winprobes

export ISTHMUS_HOME="$(mktemp -d /tmp/isthmus-it.XXXXXX)"
trap '"$CLI" kill probes >/dev/null 2>&1; rm -rf "$ISTHMUS_HOME"' EXIT
REPORT="${REPORT:-integration-report.txt}"
: > "$REPORT"

"$CLI" engine install "$ENGINE" || exit 1
"$CLI" bottle create probes || exit 1

fails=0
probe() { # required(0/1) label graphics exe [args]
  local required="$1" label="$2" graphics="$3"; shift 3
  local out
  out=$(perl -e 'alarm shift; exec @ARGV' 180 "$CLI" run -b probes ${graphics:+--graphics "$graphics"} --verbose "$@" 2>&1 \
        | grep -E '^(PASS|FAIL|SKIP) ' | head -1)
  [[ -z "$out" ]] && out="FAIL (no result: crashed or timed out)"
  printf '%-28s %s\n' "$label" "$out" | tee -a "$REPORT"
  if [[ "$required" == 1 && "$out" != PASS* ]]; then fails=$((fails + 1)); fi
}

for g in dxmt dxvk wined3d; do
  probe 1 "d3d11 x64 / $g" "$g" "$PROBES/d3d11_probe.exe"
  probe 1 "d3d11 x86 / $g" "$g" "$PROBES/d3d11_probe32.exe"
done
probe 1 "d3d12 / vkd3d" wined3d "$PROBES/d3d12_probe.exe"
if [[ -n "${D3DMETAL_TOOLKIT:-}" ]]; then
  "$CLI" d3dmetal import "$D3DMETAL_TOOLKIT" && probe 1 "d3d12 / d3dmetal" d3dmetal "$PROBES/d3d12_probe.exe"
else
  printf '%-28s %s\n' "d3d12 / d3dmetal" "SKIP set D3DMETAL_TOOLKIT=<GPTK dmg> to test" | tee -a "$REPORT"
fi
probe 1 "d3d9 x64" "" "$PROBES/d3d9_probe.exe"
probe 1 "d3d9 x86" "" "$PROBES/d3d9_probe32.exe"
probe 1 "vulkan" "" "$PROBES/vulkan_probe.exe"
probe 1 "cpu (avx advertised)" "" "$PROBES/system_probes.exe" cpu
probe 0 "net (https)" "" "$PROBES/system_probes.exe" net
probe 1 "xinput" "" "$PROBES/system_probes.exe" xinput
probe 0 "audio" "" "$PROBES/system_probes.exe" audio
probe 1 "media foundation" "" "$PROBES/system_probes.exe" media

echo "required failures: $fails" | tee -a "$REPORT"
exit $(( fails > 0 ))
