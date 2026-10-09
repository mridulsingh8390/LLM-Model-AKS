#!/bin/sh
# Init-container script: downloads the selected GGUF files into /models (skips files already present).
# Input: /scripts/models.list with lines  <alias>|<hf repo>|<file name>
set -eu
echo "Free space in /models:"; df -h /models | tail -1
while IFS='|' read -r alias repo file; do
  [ -z "${alias}" ] && continue
  dest="/models/${file}"
  if [ -s "${dest}" ]; then echo "have      ${alias} (${file})"; continue; fi
  echo "download  ${alias}: ${repo}/${file}"
  curl -fL --retry 5 --retry-delay 5 -C - -o "${dest}.part" "https://huggingface.co/${repo}/resolve/main/${file}"
  mv "${dest}.part" "${dest}"
done < /scripts/models.list
echo "All selected models are present:"; ls -lh /models
