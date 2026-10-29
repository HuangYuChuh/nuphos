set -eu
rm -f /data/.buckets-ready
/entrypoint.sh rustfs &
pid=$!
trap 'kill -TERM "$pid"' TERM INT
attempt=0
until curl -fsS http://127.0.0.1:9000/health >/dev/null 2>&1; do
  kill -0 "$pid"
  attempt=$((attempt + 1))
  test "$attempt" -le 90
  sleep 1
done
for bucket in $BUCKETS; do
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X PUT \
    --aws-sigv4 'aws:amz:us-east-1:s3' --user "$S3_ACCESS_KEY:$S3_SECRET_KEY" \
    "$S3_ENDPOINT/$bucket")
  case "$status" in
    200|409) printf 'Bucket %s ready\n' "$bucket" ;;
    *) printf 'Bucket initialization failed: HTTP %s\n' "$status" >&2; kill -TERM "$pid"; exit 1 ;;
  esac
done
touch /data/.buckets-ready
wait "$pid"
