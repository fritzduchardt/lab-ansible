#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

S3_URL=""
BUCKET_NAME=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
RESTIC_PASSWORD=""
OUT_DIR=""

usage() {
  echo """
Usage: $0 [OPTIONS] <url> <bucket> <key> <secret> <password> [out]

Restore a restic backup from S3-compatible storage.

ARGUMENTS:
  url        S3 endpoint URL (e.g., s3.amazonaws.com)
  bucket     S3 bucket name
  key        AWS Access Key ID
  secret     AWS Secret Access Key
  password   Restic repository password
  out        Output directory (default: /tmp/restore-<bucket>)

OPTIONS:
  -h, --help     Show this help message
  --url          S3 endpoint URL
  --bucket       Bucket type
  --key          AWS Access Key ID
  --secret       AWS Secret Access Key
  --password     Restic repository password
  --out          Output directory

EXAMPLES:
  # Restore immich backup to default location
  $0 s3.example.com immich AKIAIOSFODNN7EXAMPLE wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY mypassword

  # Restore vault backup to custom location
  $0 --url s3.example.com --bucket vault --key AKIAIOSFODNN7EXAMPLE \\
    --secret wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY \\
    --password mypassword --out /opt/restore/vault

  # Restore ha backup with positional arguments and custom output
  $0 s3.example.com ha AKIAIOSFODNN7EXAMPLE wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY mypassword /data/restore
"""
}

parse_args() {
  local url=""
  local bucket=""
  local key=""
  local secret=""
  local password=""
  local out=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --url)
        url="$2"
        shift 2
        ;;
      --bucket)
        bucket="$2"
        shift 2
        ;;
      --key)
        key="$2"
        shift 2
        ;;
      --secret)
        secret="$2"
        shift 2
        ;;
      --password)
        password="$2"
        shift 2
        ;;
      --out)
        out="$2"
        shift 2
        ;;
      *)
        if [[ -z "$url" ]]; then
          url="$1"
        elif [[ -z "$bucket" ]]; then
          bucket="$1"
        elif [[ -z "$key" ]]; then
          key="$1"
        elif [[ -z "$secret" ]]; then
          secret="$1"
        elif [[ -z "$password" ]]; then
          password="$1"
        elif [[ -z "$out" ]]; then
          out="$1"
        else
          log::warn "Ignoring extra argument: $1"
        fi
        shift
        ;;
    esac
  done

  S3_URL="${url:?provide s3 url}"
  BUCKET_NAME="${bucket:?provide bucket}"
  AWS_ACCESS_KEY_ID="${key:?provide aws access key id}"
  AWS_SECRET_ACCESS_KEY="${secret:?provide aws access secret key}"
  RESTIC_PASSWORD="${password:?provide restic password}"
  OUT_DIR="${out:-/tmp/restore-$BUCKET_NAME}"

  export AWS_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY
  export RESTIC_PASSWORD
}

prepare_output_directory() {
  log::info "Preparing output directory: $OUT_DIR"
  lib::exec mkdir -p "$OUT_DIR"
}

perform_restore() {
  log::info "Starting restic restore for bucket $BUCKET_NAME from s3://$S3_URL/$BUCKET_NAME to $OUT_DIR"

  # The following restic restore operation will connect to the S3-compatible
  # storage over HTTPS to download the snapshot data. It requires network
  # connectivity to the S3 endpoint and valid access credentials (AWS_ACCESS_KEY_ID
  # and AWS_SECRET_ACCESS_KEY) and the repository password (RESTIC_PASSWORD).
  # The restic client will fetch the metadata, determine the latest snapshot,
  # and stream the files to the target directory.
  if ! lib::exec "/usr/local/bin/restic" -r "s3:https://$S3_URL/$BUCKET_NAME" \
    restore latest --target "$OUT_DIR"; then
    log::error "Failed to restore from restic"
    exit 2
  fi

  log::info "Restore completed successfully to $OUT_DIR"
}

main() {
  parse_args "$@"
  prepare_output_directory
  perform_restore
}

main "$@"
