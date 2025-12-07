#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

FOLDER=""
FILE=""
ALL_IMAGES="${ALL_IMAGES:-false}"

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [FOLDER]

Iterate recursively over markdown files in FOLDER and for each file that has a matching image file (PNG or JPG) in the same folder, add an image link after the first text paragraph if not already present.

OPTIONS:
  -f FILE  Process only the specified markdown FILE
  --all-images  Add all PNG and JPG images in the folder to each markdown file, ordered by creation date
  -h       Show this help message

EXAMPLES:
  $0 /path/to/folder
  $0 -f /path/to/file.md
  $0 --all-images /path/to/folder
  $0 -h
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -f)
        if [[ -z "$2" ]]; then
          log::error "Option -f requires a FILE argument"
          usage
          exit 1
        fi
        FILE="$2"
        shift 2
        ;;
      --all-images)
        ALL_IMAGES=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$FOLDER" ]]; then
          FOLDER="$1"
        else
          log::error "Unexpected argument: $1"
          usage
          exit 1
        fi
        shift
        ;;
    esac
  done
  if [[ -n "$FILE" ]]; then
    if [[ ! -f "$FILE" ]]; then
      log::error "FILE does not exist or is not a file: $FILE"
      exit 1
    fi
    if [[ "$FILE" != *.md ]]; then
      log::error "FILE must have .md extension: $FILE"
      exit 1
    fi
  elif [[ -n "$FOLDER" ]]; then
    if [[ ! -d "$FOLDER" ]]; then
      log::error "FOLDER does not exist or is not a directory: $FOLDER"
      exit 1
    fi
  else
    log::error "Either FILE with -f or FOLDER is required"
    usage
    exit 1
  fi
}

process_file() {
  local file="$1"
  local base
  base=$(basename "$file" .md)
  local dir
  dir=$(dirname "$file")
  local image_file=""
  if [[ -f "$dir/$base.png" ]]; then
    image_file="$base.png"
  elif [[ -f "$dir/$base.jpg" ]]; then
    image_file="$base.jpg"
  fi
  if [[ -n "$image_file" ]]; then
    if ! grep -q "$image_file" "$file"; then
      log::info "Adding image link to $file"
      local inserted=0
      local temp_file="$file.tmp"
      local found_headline=0
      local found_paragraph=0
      while IFS= read -r line; do
        if [[ $inserted -eq 0 && $found_headline -eq 1 && $found_paragraph -eq 1 && "$line" == "" ]]; then
          echo "" >> "$temp_file"
          echo "![]($image_file)" >> "$temp_file"
          inserted=1
        fi
        if [[ $found_headline -eq 0 && "$line" =~ ^# ]]; then
          found_headline=1
        elif [[ $found_headline -eq 1 && "$line" != "" ]]; then
          found_paragraph=1
        fi
        echo "$line" >> "$temp_file"
      done < "$file"
      if [[ $inserted -eq 0 ]]; then
        echo "" >> "$temp_file"
        echo "![]($image_file)" >> "$temp_file"
      fi
      lib::exec mv "$temp_file" "$file"
    else
      log::info "Image link already present in $file"
    fi
  fi
}

process_all_images() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  local image_files
  image_files=($(lib::exec find "$dir" -maxdepth 1 \( -name "*.png" -o -name "*.jpg" \) -type f -print0 | xargs -0 ls -tr 2>/dev/null))
  if [[ ${#image_files[@]} -eq 0 ]]; then
    return
  fi
  local images_to_add=()
  for png in "${image_files[@]}"; do
    local base
    base=$(basename "$png")
    if ! grep -q "$base" "$file"; then
      images_to_add+=("$base")
    fi
  done
  if [[ ${#images_to_add[@]} -eq 0 ]]; then
    log::info "All image links already present in $file"
    return
  fi
  log::info "Adding image links to $file"
  local inserted=0
  local temp_file="$file.tmp"
  local found_headline=0
  local found_paragraph=0
  while IFS= read -r line; do
    if [[ $inserted -eq 0 && $found_headline -eq 1 && $found_paragraph -eq 1 && "$line" == "" ]]; then
      for img in "${images_to_add[@]}"; do
        echo "" >> "$temp_file"
        echo "![]($img)" >> "$temp_file"
      done
      inserted=1
    fi
    if [[ $found_headline -eq 0 && "$line" =~ ^# ]]; then
      found_headline=1
    elif [[ $found_headline -eq 1 && "$line" != "" ]]; then
      found_paragraph=1
    fi
    echo "$line" >> "$temp_file"
  done < "$file"
  if [[ $inserted -eq 0 ]]; then
    for img in "${images_to_add[@]}"; do
      echo "" >> "$temp_file"
      echo "![]($img)" >> "$temp_file"
    done
  fi
  lib::exec mv "$temp_file" "$file"
}

main() {
  parse_args "$@"
  local process_func
  if [[ "$ALL_IMAGES" == "true" ]]; then
    process_func=process_all_images
  else
    process_func=process_file
  fi
  if [[ -n "$FILE" ]]; then
    log::info "Processing single file: $FILE"
    $process_func "$FILE"
    log::info "Processing completed"
  else
    log::info "Starting processing of markdown files in $FOLDER"
    while IFS= read -r file; do
      $process_func "$file"
    done < <(lib::exec find "$FOLDER" -name "*.md" -type f)
    log::info "Processing completed"
  fi
}

main "$@"
