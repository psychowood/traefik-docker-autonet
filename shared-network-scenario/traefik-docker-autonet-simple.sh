#!/bin/sh
# Configuration
REVERSE_PROXY_NETWORK="${REVERSE_PROXY_NETWORK:-reverse-proxy}"
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"

echo "Starting network manager...";
echo "Reverse proxy network: $REVERSE_PROXY_NETWORK";
echo "Traefik container: $TRAEFIK_CONTAINER";

# Connect existing traefik-enabled containers
echo "Processing existing containers...";
docker ps --filter "label=traefik.enable=true" --format "{{.Names}}" | while read container_name; do
  echo "Connecting $container_name to $REVERSE_PROXY_NETWORK";
  docker network connect $REVERSE_PROXY_NETWORK $container_name 2>/dev/null || echo "Already connected";
done;

echo "Watching for container events...";
docker events --filter "type=container" --filter "event=create" --filter "event=destroy" --format "{{.Time}} {{.Action}} {{.Actor.Attributes.name}}" | while read event_time status container_name; do
  # Check if container has traefik.enable label
  if [ "$(docker inspect --format "{{index .Config.Labels \"traefik.enable\"}}" $container_name 2>/dev/null)" != "true" ]; then
    continue;
  fi;
  
  formatted_time=$(date -u -d @$event_time '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || echo "$event_time");
  echo "Event at $formatted_time: $status for container: $container_name";
  
  # Handle container create
  if [ "$status" = "create" ]; then
    echo "Connecting $container_name to $REVERSE_PROXY_NETWORK";
    docker network connect $REVERSE_PROXY_NETWORK $container_name;
  fi;
  
  # Handle container destroy - remove from network
  if [ "$status" = "destroy" ]; then
    echo "Disconnecting $container_name from $REVERSE_PROXY_NETWORK";
    docker network disconnect $REVERSE_PROXY_NETWORK $container_name;
  fi;
done;
echo "End of loop. Should not see this.";
