# Configuration
NETWORK_SUFFIX="${NETWORK_SUFFIX:-traefik-autonet}"
TRAEFIK_CONTAINER="${TRAEFIK_CONTAINER:-traefik}"
AUTONET_SUBNET="${AUTONET_SUBNET:-172.30.0.0/16}"

echo "Starting network manager...";
echo "Network suffix: $NETWORK_SUFFIX";
echo "Traefik container: $TRAEFIK_CONTAINER";
echo "Autonet subnet: $AUTONET_SUBNET";

# Function to convert IP address to integer
ip_to_int() {
  local ip=$1
  local IFS=.
  local -a parts=($ip)
  echo $((parts[0] * 256**3 + parts[1] * 256**2 + parts[2] * 256 + parts[3]))
}

# Function to convert integer to IP address
int_to_ip() {
  local int=$1
  echo "$((int / 256**3 % 256)).$((int / 256**2 % 256)).$((int / 256 % 256)).$((int % 256))"
}

# Function to find next available /30 subnet
find_next_subnet() {
  local base_subnet=$1
  local base_ip=$(echo $base_subnet | cut -d'/' -f1)
  local base_int=$(ip_to_int $base_ip)
  
  # Get all used subnets from existing autonet networks
  local used_subnets=$(docker network ls --filter "name=-${NETWORK_SUFFIX}$" --format "{{.Name}}" | while read net; do
    docker network inspect $net --format "{{range .IPAM.Config}}{{.Subnet}}{{end}}"
  done)
  
  local current_int=$base_int
  # Iterate through /30 boundaries (every 4 addresses)
  while true; do
    local candidate_ip=$(int_to_ip $current_int)
    local candidate_subnet="${candidate_ip}/30"
    
    # Check if this subnet is already used
    if ! echo "$used_subnets" | grep -q "$candidate_subnet"; then
      echo "$candidate_subnet"
      return
    fi
    
    current_int=$((current_int + 4))
    
    # Safety check: don't go beyond the /16
    local max_int=$((base_int + 65536))
    if [ $current_int -ge $max_int ]; then
      echo "ERROR: No available subnets in $base_subnet" >&2
      return 1
    fi
  done
}

# Get networks that traefik is connected to
echo "Getting Traefik's networks...";
TRAEFIK_NETWORKS=$(docker inspect --format "{{range \$k, \$v := .NetworkSettings.Networks}}{{println \$k}}{{end}}" $TRAEFIK_CONTAINER 2>/dev/null | tr '\n' ' ');
echo "Traefik is connected to: $TRAEFIK_NETWORKS";

# Cleanup function for orphaned networks on startup
echo "Cleaning up orphaned networks...";
docker network ls --filter "name=-${NETWORK_SUFFIX}$" --format "{{.Name}}" | while read network_name; do
  container_name=$(echo "$network_name" | sed "s/-${NETWORK_SUFFIX}$//");
  # Check if container exists and is running
  if ! docker ps --format "{{.Names}}" | grep -q "^${container_name}$"; then
    echo "Removing orphaned network: $network_name";
    docker network disconnect $network_name $TRAEFIK_CONTAINER;
    docker network rm $network_name;
  fi;
done;

echo "Processing existing containers...";
docker ps --filter "label=traefik.enable=true" --format "{{.Names}}" | while read container_name; do
  echo "Found container: $container_name";
  
  # Check if container shares any networks with traefik (excluding the auto-created ones)
  shared_network_found=0;
  container_networks=$(docker inspect --format "{{range \$k, \$v := .NetworkSettings.Networks}}{{println \$k}}{{end}}" $container_name 2>/dev/null);
  for net in $container_networks; do
    # Skip if it's already an auto-created network
    if echo "$net" | grep -qE "\-${NETWORK_SUFFIX}$"; then
      continue;
    fi;
    # Check if traefik is also on this network
    if echo "$TRAEFIK_NETWORKS" | grep -qw "$net"; then
      echo "INFO: Container $container_name is already connected to network '$net' shared with Traefik - skipping automatic network creation";
      shared_network_found=1;
      break;
    fi;
  done;
  
  # Only create automatic network if no shared network was found
  if [ $shared_network_found -eq 0 ]; then
    network_name="${container_name}-${NETWORK_SUFFIX}";
    subnet=$(find_next_subnet "$AUTONET_SUBNET");
    
    if [ -z "$subnet" ]; then
      echo "ERROR: Could not find available subnet for $container_name";
      continue;
    fi;
    
    # Create internal network with specific subnet
    echo "Creating internal network: $network_name with subnet $subnet";
    docker network create --internal --subnet $subnet $network_name;
    
    # Connect container to the network
    echo "Connecting $container_name to $network_name";
    docker network connect $network_name $container_name;
    
    # Connect traefik to the network
    echo "Connecting $TRAEFIK_CONTAINER to $network_name";
    docker network connect $network_name $TRAEFIK_CONTAINER;
  fi;
done;

echo "Watching for container events...";
docker events --filter "type=container" --filter "event=create" --filter "event=destroy" --format "{{.Time}} {{.Action}} {{.Actor.Attributes.name}}" | while read event_time status container_name; do
  # Check if container has traefik.enable label
  if [ "$(docker inspect --format "{{index .Config.Labels \"traefik.enable\"}}" $container_name 2>/dev/null)" != "true" ]; then
    continue;
  fi;
  
  formatted_time=$(date -u -d @$event_time '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "$event_time");
  echo "Event at $formatted_time: $status for container: $container_name";
  
  # Handle container create
  if [ "$status" = "create" ]; then
    
    # Refresh traefik networks list
    TRAEFIK_NETWORKS=$(docker inspect --format "{{range \$k, \$v := .NetworkSettings.Networks}}{{println \$k}}{{end}}" $TRAEFIK_CONTAINER 2>/dev/null | tr '\n' ' ');
    
    # Check if container shares any networks with traefik
    shared_network_found=0;
    container_networks=$(docker inspect --format "{{range \$k, \$v := .NetworkSettings.Networks}}{{println \$k}}{{end}}" $container_name 2>/dev/null);
    for net in $container_networks; do
      if echo "$net" | grep -qE "\-${NETWORK_SUFFIX}$"; then
        continue;
      fi;
      if echo "$TRAEFIK_NETWORKS" | grep -qw "$net"; then
        echo "INFO: Container $container_name is already connected to network '$net' shared with Traefik - skipping automatic network creation";
        shared_network_found=1;
        break;
      fi;
    done;
    
    # Only create automatic network if no shared network was found
    if [ $shared_network_found -eq 0 ]; then
      network_name="${container_name}-${NETWORK_SUFFIX}";
      subnet=$(find_next_subnet "$AUTONET_SUBNET");
      
      if [ -z "$subnet" ]; then
        echo "ERROR: Could not find available subnet for $container_name";
        continue;
      fi;
      
      # Create internal network with specific subnet
      echo "Creating internal network: $network_name with subnet $subnet";
      docker network create --internal --subnet $subnet $network_name;
      
      # Connect container to the network
      echo "Connecting $container_name to $network_name";
      docker network connect $network_name $container_name;
      
      # Connect traefik to the network
      echo "Connecting $TRAEFIK_CONTAINER to $network_name";
      docker network connect $network_name $TRAEFIK_CONTAINER;
    fi;
  fi;
  
  # Handle container destroy - remove network only
  if [ "$status" = "destroy" ]; then
    echo "Container $container_name destroyed - cleaning up network";
    network_name="${container_name}-${NETWORK_SUFFIX}";
    
    # Check if network exists and remove it
    if docker network inspect $network_name >/dev/null 2>&1; then
      echo "Removing network: $network_name";
      docker network rm $network_name;
    fi;
  fi;
done;
echo "End of loop. Should not see this.";