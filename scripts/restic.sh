#!/usr/bin/bash

url="s3.eu-central-3.ionoscloud.com"
bucket_name="friclu-1"
key_id="${1:?provide aws access key id}"
secret="${2:?provide aws access secret key}"
password="${3:?provide restic password}"

export AWS_ACCESS_KEY_ID="$key_id"
export AWS_SECRET_ACCESS_KEY="$secret"
export RESTIC_PASSWORD="$password"

restic -r "s3:https://$url/$bucket_name" snapshots
