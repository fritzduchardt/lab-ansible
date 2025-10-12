#!/usr/bin/bash

url="s3.eu-central-3.ionoscloud.com"
bucket_name="${1:?provide bucket name}"
key_id="${2:?provide aws access key id}"
secret="${3:?provide aws access secret key}"
password="${4:?provide restic password}"
shift 4

export AWS_ACCESS_KEY_ID="$key_id"
export AWS_SECRET_ACCESS_KEY="$secret"
export RESTIC_PASSWORD="$password"

restic -r "s3:https://$url/$bucket_name" "${@}"
