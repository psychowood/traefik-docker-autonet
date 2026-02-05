#!/bin/sh
# Configuration
REVERSE_PROXY_NETWORK="${REVERSE_PROXY_NETWORK:-reverse-proxy}"
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"
RETRIES="${RETRIES:-5}"
RETRY_DELAY="${RETRY_DELAY:-1}"

echo "Starting network manager...";
echo "Reverse proxy network: $REVERSE_PROXY_NETWORK";
echo "Traefik container: $TRAEFIK_CONTAINER";

# Connect existing traefik-enabled containers
echo "Processing existing containers...";
docker ps --filter "label=traefik.enable=true" --format "{{.Names}}" | while read container_name; do
  echo "Connecting $container_name to $REVERSE_PROXY_NETWORK";
  docker network connect $REVERSE_PROXY_NETWORK $container_name 2>/dev/null || echo "Already connected";
done;

# helper: wait for container label traefik.enable=true (returns 0 if found)
wait_for_label() {
  container="$1"
  i=0
  while [ "$i" -lt "$RETRIES" ]; do
    val=$(docker inspect --format '{{index .Config.Labels "traefik.enable"}}' "$container" 2>/dev/null || true)
    if [ "$val" = "true" ]; then
      return 0
    fi
    i=$((i+1))
    sleep "$RETRY_DELAY"
  done
  return 1
}

# helper: check if container already connected to network
is_connected() {
  container="$1"
  docker inspect --format '{{json .NetworkSettings.Networks}}' "$container" 2>/dev/null | grep -q "\"$REVERSE_PROXY_NETWORK\"" || return 1
  return 0
}

echo "Watching for container events...";
# listen for create and start events
docker events --filter "type=container" --filter "event=create" --filter "event=start" --format "{{.Time}} {{.Action}} {{.Actor.Attributes.name}}" | while read event_time status container_name; do
  # ignore empty names
  [ -z "$container_name" ] && continue

  formatted_time=$(date -u -d @$event_time '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "$event_time")
  echo "Event at $formatted_time: $status for container: $container_name";

  case "$status" in
    create|start)
      # Wait for label to be available (handles restart races)
      if ! wait_for_label "$container_name"; then
        echo "traefik.enable label not present for $container_name after retries; skipping";
        continue
      fi

      # If already connected, skip
      if is_connected "$container_name"; then
        echo "$container_name already connected to $REVERSE_PROXY_NETWORK";
        continue
      fi

      # Try connecting with retries to handle transient docker races
      attempt=0
      while [ "$attempt" -lt "$RETRIES" ]; do
        echo "Attempting to connect $container_name to $REVERSE_PROXY_NETWORK (try $((attempt+1))/$RETRIES)"
        if docker network connect "$REVERSE_PROXY_NETWORK" "$container_name" 2>/dev/null; then
          echo "Connected $container_name to $REVERSE_PROXY_NETWORK"
          break
        fi
        attempt=$((attempt+1))
        sleep "$RETRY_DELAY"
      done

      if [ "$attempt" -ge "$RETRIES" ]; then
        echo "Failed to connect $container_name to $REVERSE_PROXY_NETWORK after $RETRIES attempts"
      fi
      ;;
  esac
done;
echo "End of loop. Should not see this.";
