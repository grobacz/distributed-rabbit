#!/bin/sh
set -e

wait_for_node() {
    host="$1"
    port="$2"
    name="$3"
    echo "--- Waiting for $name to be ready..."
    until curl -sf -u "$CREDS" "http://${host}:${port}/api/aliveness-test/%2f" > /dev/null 2>&1; do
        echo "    $name not ready, retrying in 3s..."
        sleep 3
    done
    echo "    $name is ready."
}

RABBIT1_HOST="rabbit1"
RABBIT1_MGMT_PORT="15672"
RABBIT2_HOST="rabbit2"
RABBIT2_MGMT_PORT="15672"

RABBIT1_API="http://${RABBIT1_HOST}:${RABBIT1_MGMT_PORT}/api"
RABBIT2_API="http://${RABBIT2_HOST}:${RABBIT2_MGMT_PORT}/api"

CREDS="guest:guest"

wait_for_node "$RABBIT1_HOST" "$RABBIT1_MGMT_PORT" "RabbitMQ #1 (upstream)"
wait_for_node "$RABBIT2_HOST" "$RABBIT2_MGMT_PORT" "RabbitMQ #2 (downstream)"

echo ""
echo "=== Declaring federation.in exchange on RabbitMQ #1 (upstream) ==="
curl -sf -u "$CREDS" -X PUT \
    "${RABBIT1_API}/exchanges/%2f/federation.in" \
    -H "content-type: application/json" \
    -d '{"type":"direct","durable":true}'
echo " done"

echo "=== Declaring federation.in exchange on RabbitMQ #2 (downstream) ==="
curl -sf -u "$CREDS" -X PUT \
    "${RABBIT2_API}/exchanges/%2f/federation.in" \
    -H "content-type: application/json" \
    -d '{"type":"direct","durable":true}'
echo " done"

echo "=== Declaring consumer.queue on RabbitMQ #2 (downstream) ==="
curl -sf -u "$CREDS" -X PUT \
    "${RABBIT2_API}/queues/%2f/consumer.queue" \
    -H "content-type: application/json" \
    -d '{"durable":true}'
echo " done"

echo "=== Binding consumer.queue to federation.in on RabbitMQ #2 ==="
curl -sf -u "$CREDS" -X POST \
    "${RABBIT2_API}/bindings/%2f/e/federation.in/q/consumer.queue" \
    -H "content-type: application/json" \
    -d '{"routing_key":""}'
echo " done"

echo "=== Declaring upstream on RabbitMQ #2 pointing to RabbitMQ #1 ==="
curl -sf -u "$CREDS" -X PUT \
    "${RABBIT2_API}/parameters/federation-upstream/%2f/rabbit1-upstream" \
    -H "content-type: application/json" \
    -d '{"component":"federation-upstream","name":"rabbit1-upstream","value":{"uri":"amqp://guest:guest@rabbit1","ack-mode":"on-confirm"}}'
echo " done"

echo "=== Setting federation policy on RabbitMQ #2 ==="
curl -sf -u "$CREDS" -X PUT \
    "${RABBIT2_API}/policies/%2f/federation-policy" \
    -H "content-type: application/json" \
    -d '{"pattern":"^federation\\.in$","definition":{"federation-upstream":"rabbit1-upstream"},"priority":1,"apply-to":"exchanges"}'
echo " done"

echo ""
echo "=== Setup complete. Verifying federation link ==="
sleep 2
echo "--- Federation links on RabbitMQ #2 ---"
curl -sf -u "$CREDS" "${RABBIT2_API}/federation-links"

echo ""
echo ""
echo "=== All done! ==="
echo "  RabbitMQ #1 management: http://localhost:15672  (guest/guest)"
echo "  RabbitMQ #2 management: http://localhost:15673  (guest/guest)"
echo ""
echo "  To test: publish to federation.in on rabbit1 and check consumer.queue on rabbit2"