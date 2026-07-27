#!/bin/bash

set -euo pipefail

cd "$(dirname "$0")/.."

status=0
deleted_names=(
  'AudioChannelConfigurationAvailability'
  'inputHasStereoSource'
  'isConfiguredForStereo'
  'shouldAutoSelectStereoWhenAvailable'
  'availableChannelCountsForSelectedSource'
  'channelConfigurationAvailability'
  'AudioInputPickingEnvironment'
  'AudioInputPreferenceController'
  'AudioInputPreferenceRestorer'
  'AudioEnvironmentPreferenceStore'
  'func applyMono\('
  'func applyStereo\('
  'func applySourceConfiguration\('
)

for pattern in "${deleted_names[@]}"; do
  if rg -n --glob '*.swift' --glob '*.md' "$pattern" Sources; then
    echo "Deleted input-configuration API reintroduced: $pattern" >&2
    status=1
  fi
done

if rg -n --glob 'AudioEnvironmentManager*.swift' \
  'public( private\(set\))? var (channels|sampleRate|selectedInput|selectedSource|useMeasurement)\b' \
  Sources/AIOAudioSession/Env
then
  echo "Deleted scalar AudioEnvironmentManager configuration API reintroduced." >&2
  status=1
fi

exit "$status"
