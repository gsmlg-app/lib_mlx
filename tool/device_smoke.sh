#!/usr/bin/env bash
# Signed Release installation + independent launch of the existing Flutter example.
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: tool/device_smoke.sh UDID MODEL_PATH [CONTEXT_LENGTH=4096]" >&2
  exit 64
fi
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
device_udid="$1"
model_path="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve(strict=True))' "$2")"
context_length="${3:-4096}"
if [[ ! "$context_length" =~ ^[1-9][0-9]{0,5}$ ]] || (( context_length > 131072 )); then
  echo "CONTEXT_LENGTH must be an integer in 1...131072" >&2
  exit 64
fi
bundle_id='app.gsmlg.libMlxExample'
run_id="$(date -u +%Y%m%dT%H%M%SZ)-$(uuidgen | tr '[:upper:]' '[:lower:]')"
output_dir="$repo_root/build/device-smoke/$run_id"
mkdir -p "$output_dir"
exec > >(tee "$output_dir/run.log") 2>&1

# Verify locally without downloading, rewriting a manifest, or deleting model assets.
PYTHONDONTWRITEBYTECODE=1 python3 - "$model_path" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('fetch_model', 'tool/fetch_model.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
model = Path(sys.argv[1])
lock = json.loads(Path('tool/model-lock.json').read_text())
if not model.is_dir():
    raise SystemExit('MODEL_PATH must be an existing verified model directory')
for entry in lock['files']:
    if not module.verify(model / entry['path'], entry):
        raise SystemExit(f"Missing or corrupt model asset: {entry['path']}; recover with tool/fetch_model.py before running device smoke")
try:
    manifest = json.loads((model / 'lib_mlx-model.json').read_text())
except (OSError, ValueError) as error:
    raise SystemExit(f'Missing or invalid lib_mlx-model.json: {error}')
if manifest != lock:
    raise SystemExit('Model manifest differs from the pinned model lock')
print(f"Verified {lock['repository']}@{lock['revision']}")
PY
source_digest="$(python3 tool/release_gate.py --source-digest)"
python3 tool/package_manifests.py --check
export FLUTTER_SWIFT_PACKAGE_MANAGER=true
flutter pub get
(
  cd example
  flutter pub get
  flutter build ios --release --target lib/smoke.dart \
    "--dart-define=LIB_MLX_CONTEXT_LENGTH=$context_length" \
    "--dart-define=LIB_MLX_SOURCE_DIGEST=$source_digest" \
    "--dart-define=LIB_MLX_SMOKE_RUN_ID=$run_id"
)
app_path="$repo_root/example/build/ios/iphoneos/Runner.app"
if [[ ! -d "$app_path" ]]; then
  echo "Missing signed Release Flutter example: $app_path" >&2
  exit 1
fi
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")" != "$bundle_id" ]]; then
  echo "Refusing to install a bundle with an unexpected identifier" >&2
  exit 1
fi
codesign --verify --deep --strict "$app_path"
codesign --display --verbose=4 "$app_path" 2> "$output_dir/signing.txt"
# Inspect the actual signed executable, not the project's requested entitlements.
codesign --display --entitlements - --xml "$app_path" \
  > "$output_dir/signed-entitlements.plist" 2> "$output_dir/entitlements.log"
plutil -lint "$output_dir/signed-entitlements.plist"
if grep -q '^Signature=adhoc' "$output_dir/signing.txt"; then
  echo "iOS device smoke requires a provisioned signature; ad-hoc code signing is insufficient" >&2
  exit 1
fi
if [[ "$(python3 tool/release_gate.py --source-digest)" != "$source_digest" ]]; then
  echo "Source changed while building. Rebuild before generating release evidence." >&2
  exit 1
fi

run_device() {
  if ! xcrun devicectl "$@"; then
    echo "Device operation failed for $device_udid. If the device is locked or untrusted, unlock/trust it and rerun; no device settings were changed." >&2
    exit 1
  fi
}
run_device device install app --device "$device_udid" "$app_path" \
  --timeout 120 --json-output "$output_dir/install.json"
# devicectl skips unchanged files and merges this verified snapshot into the model directory.
# Explicit false prevents removal of existing destination contents.
run_device device copy to --device "$device_udid" --source "$model_path" \
  --destination Documents/gemma-4-e2b --domain-type appDataContainer \
  --domain-identifier "$bundle_id" --remove-existing-content false \
  --timeout 900 --json-output "$output_dir/model-copy.json"
run_device device process launch --device "$device_udid" --terminate-existing "$bundle_id" \
  --timeout 25 --json-output "$output_dir/launch.json"

# No debugger or console bridge: the installed Release app runs independently.
# Each poll is bounded below 30 seconds, and the complete poll window is bounded.
deadline=$((SECONDS + 900))
while (( SECONDS < deadline )); do
  if xcrun devicectl device copy from --device "$device_udid" \
    --source Documents/lib_mlx-smoke-report.json --destination "$output_dir/report-candidate.json" \
    --domain-type appDataContainer --domain-identifier "$bundle_id" \
    --timeout 15 --json-output "$output_dir/report-copy.json" > "$output_dir/poll.log" 2>&1; then
    if python3 - "$output_dir/report-candidate.json" "$output_dir/report.json" "$run_id" "$source_digest" "$device_udid" "$output_dir/signed-entitlements.plist" <<'PY'
import json
from pathlib import Path
import plistlib
import sys
try:
    report = json.loads(Path(sys.argv[1]).read_text())
except (OSError, ValueError):
    raise SystemExit(2)
if not isinstance(report, dict) or report.get('run_id') != sys.argv[3] or report.get('source_digest') != sys.argv[4]:
    raise SystemExit(2)  # A stale report cannot satisfy this invocation.
with Path(sys.argv[6]).open('rb') as signed_entitlements:
    entitlements = plistlib.load(signed_entitlements)
report.update(signed=True, signing_kind='provisioned', standalone_launch=True, device_udid=sys.argv[5],
              increased_memory_limit_entitlement=entitlements.get('com.apple.developer.kernel.increased-memory-limit') is True)
Path(sys.argv[2]).write_text(json.dumps(report, indent=2) + '\n')
PY
    then
      python3 tool/release_gate.py --platform ios --run-id "$run_id" "$output_dir/report.json"
      echo "Signed standalone iOS Flutter Release evidence: $output_dir/report.json"
      exit 0
    fi
  fi
  sleep 5
done
echo "No fresh smoke report within 900 seconds; inspect $output_dir/run.log and poll.log. A locked device must be unlocked before retrying." >&2
exit 1
