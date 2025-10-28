#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

usage() {
  echo """Usage: $0 [options]

Options:
  -f, --file FILE       File to import or delete (required)
  -b, --base BASE       Base path to strip from file paths (default: directory of the file)
  -e, --endpoint URL    Weaviate endpoint URL (default: http://localhost:8080)
  -c, --class NAME      Weaviate class name to operate on (default: ObsidianFile)
  -d, --delete          Delete the object matching the file path from Weaviate
  -h, --help            Show this help

Examples:
  $0 --file ./docs/notes.md --base ./docs --endpoint http://weaviate.local:8080 --class Document
  $0 -f /data/texts/note.md -b /data -e http://127.0.0.1:8080 -c MyTextClass
  $0 -f ./docs/old.md --delete -e http://weaviate.local:8080 -c Document
"""
}

weaviate::import_file() {
  local endpoint="$1"
  local class="$2"
  local base="$3"
  local file="$4"
  local base_abs
  local file_abs
  local base_path
  local rel
  local payload
  local rc

  log::info "Preparing import for file: $file"

  base_abs="$(lib::exec realpath -- "$base")"
  file_abs="$(lib::exec realpath -- "$file")"

  base_path="${base_abs%/}"
  if [[ -n "$base_path" ]] && [[ "$file_abs" == "$base_path"* ]]; then
    rel="${file_abs#$base_path/}"
  else
    log::error "Base path: $base_path does not match file path: $file_abs"
    exit 2
  fi

  payload="$(lib::exec jq -Rs --arg class "$class" --arg path "$rel" '{class: $class, properties: {path: $path, content: .}}' <"$file_abs")"
  log::debug "Payload for $file_abs: $payload"

  if ! lib::exec curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$endpoint/v1/objects"; then
    rc=$?
    log::error "Failed to POST object for $file_abs (exit $rc)"
    return 1
  fi
}

weaviate::find_object_id() {
  local endpoint="$1"
  local class="$2"
  local base="$3"
  local file="$4"
  local rel
  local payload
  local resp
  local rc
  local id

  rel="${file#$base}"
  log::info "Searching for object id for file: $rel"

  payload="$(cat <<EOF
{
  "query": "{
    Get {
      ObsidianFile(where: {
        path: [\"path\"],
        operator: Equal,
        valueText: \"$rel\"
      }) {
        _additional { id }
      }
    }
  }"
}
EOF
)"
  resp="$(lib::exec echo $payload | curl -sS -X POST -H "Content-Type: application/json" -d @- "$endpoint/v1/graphql")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log::error "GraphQL request failed for search (exit $rc)"
    return 3
  fi
  id="$(lib::exec jq -r --arg class "$class" '.data.Get[$class][0]._additional.id' <<<"$resp")"
  if [[ "$id" == "null" ]] || [[ -z "$id" ]]; then
    log::warn "No object found for path: $rel"
    echo ""
    return 0
  fi

  echo "$id"
  return 0
}

weaviate::delete_file() {
  local endpoint="$1"
  local class="$2"
  local base="$3"
  local file="$4"
  local id
  local rc

  log::info "Attempting delete for file: $file"

  id="$(weaviate::find_object_id "$endpoint" "$class" "$base" "$file")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log::error "Failed to search object id (exit $rc)"
    return $rc
  fi

  if [[ -z "$id" ]]; then
    log::warn "Nothing to delete for file: $file"
    return 0
  fi

  if ! lib::exec curl -sS -X DELETE "$endpoint/v1/objects/$id"; then
    rc=$?
    log::error "Failed to DELETE object id $id (exit $rc)"
    return 1
  fi

  log::info "Deleted object id $id for file: $file"
  return 0
}

main() {
  local file
  local base
  local endpoint
  local class
  local delete_mode

  file="${FILE}"
  endpoint="${ENDPOINT:-http://weaviate.weaviate}"
  class="${CLASS:-ObsidianFile}"
  base="${BASE:-/volumes/syncthing}"
  delete_mode="0"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        file="$2"
        shift 2
        ;;
      -b|--base)
        base="$2"
        shift 2
        ;;
      -e|--endpoint)
        endpoint="$2"
        shift 2
        ;;
      -c|--class)
        class="$2"
        shift 2
        ;;
      -d|--delete)
        delete_mode="1"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log::error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ -z "$file" ]]; then
    log::error "No file specified"
    usage
    exit 1
  fi

  if [[ ! "$file" =~ [Pp]rotocol|[Jj]ournal\.md ]]; then
    log::info "Not processing: $file"
    exit 0
  fi

  if [[ "$delete_mode" == "0" && ! -f "$file" ]]; then
    log::error "File not found: $file"
    exit 1
  fi

  if [[ -z "$base" ]]; then
    base="$(lib::exec dirname -- "$file")"
  fi

  if [[ "$delete_mode" == "1" ]]; then
    weaviate::delete_file "$endpoint" "$class" "$base" "$file"
    exit $?
  fi

  weaviate::import_file "$endpoint" "$class" "$base" "$file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
