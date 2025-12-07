#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../log.sh"
source "$SCRIPT_DIR/../utils.sh"

FOLDER=""
FILE=""

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [FOLDER]

Extracts first paragraph from md file
OPTIONS:
  -f FILE  Process only the specified markdown FILE
  -h       Show this help message

EXAMPLES:
  $0 -f /path/to/file.md
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
      -h|--help)
        usage
        exit 0
        ;;
      *)
    esac
  done
  if [[ -z "$FILE" ]]; then
      log::error "FILE not specified"
      exit 1
  elif [[ -n "$FILE" ]]; then
    if [[ ! -f "$FILE" ]]; then
      log::error "FILE does not exist or is not a file: $FILE"
      exit 1
    fi
    if [[ "$FILE" != *.md ]]; then
      log::error "FILE must have .md extension: $FILE"
      exit 1
    fi
  fi
}

process_file() {
  local file="$1" line
  local first_paragraph=""
  local first_paragraph_start=0
  while IFS= read -r line; do
    if [[ "$line" != "" && "$line" != *".png"* && "$line" != "#"* ]];
    then
      first_paragraph_start=1
      first_paragraph+="$line"
    elif [[ $first_paragraph_start -eq 1 && "$line" == "" ]]; then
      break
    fi
  done < "$file"
  echo "$first_paragraph"
}

main() {
  parse_args "$@"
  log::info "Processing file: $FILE"
  process_file "$FILE"
  log::info "Processing completed"
}

main "$@"
