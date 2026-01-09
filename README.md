# traefik-docker-autonet

Minimal shell-based container to automate connecting Traefik to containers.

## Overview

This project provides a lightweight Docker container that automatically manages network connectivity between Traefik and your application containers. When a container with the `traefik.enable=true` label starts, the script automatically creates a dedicated internal network and connects both the container and Traefik to it.

## Problem Statement

In Docker environments with Traefik as a reverse proxy, containers need to be on the same network as Traefik to be accessible. Manually managing these network connections becomes tedious, especially in dynamic environments where containers are frequently created and destroyed; moreover reusing a common reverse proxy network is not a best practice because that way containers are not isolated, even if it could be accettable in some scenarios (see 'Simplified Setup' below).

## Solution

This tool (script) monitors Docker events and automatically:

- Creates dedicated internal networks for each Traefik-enabled container
- Connects both the container and Traefik to these networks
- Cleans up networks when containers are removed
- Skips automatic network creation if the container already shares a network with Traefik, after logging it

## Features

- **Automatic network management**: Creates and destroys networks based on container lifecycle
- **Internal-only networks**: All auto-created networks are internal (no external connectivity)
- **Smart detection**: Skips network creation if container already shares a network with Traefik
- **Cleanup on startup**: Removes orphaned networks from previous runs
- **Configurable**: Network suffix and Traefik container name are configurable via environment variables
- **Minimal footprint**: Uses the `docker:cli` image with a simple shell script
- **Event-driven**: Monitors Docker events in real-time for immediate response

## How It Works

1. **On startup**: Scans existing containers with `traefik.enable=true` and sets up networks
2. **On container creation**: Detects new containers with the label and creates dedicated networks automatically
3. **On container destruction**: Removes the dedicated network
4. **Continuous monitoring**: Watches Docker events stream for real-time updates, without polling

## Requirements

- Docker environment
- Traefik running as a container
- Access to Docker socket (directly or via docker-socket-proxy)

## Usage

### Simplified Setup (Shared Reverse Proxy Network)

This is the simplest approach: all traefik-enabled containers connect to a single shared network with Traefik.

**For detailed documentation, see [shared-network-scenario/README.md](shared-network-scenario/README.md)**

Quick start:

```bash
cd shared-network-scenario
wget -O traefik-docker-autonet.sh traefik-docker-autonet-simple.sh
chmod +x traefik-docker-autonet.sh
```

Then follow the configuration steps in the [shared-network-scenario README](shared-network-scenario/README.md).

### Advanced Setup (Per-Container Isolated Networks)

For stronger isolation, use the full version which creates a dedicated network for each container with automatic subnet allocation.

Download the script:

```bash
wget -O traefik-docker-autonet.sh https://raw.githubusercontent.com/psychowood/traefik-docker-autonet/main/traefik-docker-autonet.sh
chmod +x traefik-docker-autonet.sh
```

Use it in your docker-compose.yml:

```yaml
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "80:80"
      - "443:443"

  traefik-docker-autonet:
    image: docker:cli
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./traefik-docker-autonet.sh:/app/traefik-docker-autonet.sh:ro
    environment:
      - NETWORK_SUFFIX=traefik-autonet
      - AUTONET_SUBNET=172.30.0.0/16
      - TRAEFIK_CONTAINER=traefik
    command: sh /app/traefik-docker-autonet.sh
    restart: unless-stopped
```

### With Docker Socket Proxy (Recommended for Security)

For enhanced security, use a Docker socket proxy to limit Docker API access. Both `traefik` and `traefik-docker-autonet` should set `DOCKER_HOST=tcp://{proxy-service}:2375` and connect to the proxy network.

#### Example Docker Compose Structure

```yaml
services:
  traefik:
    image: traefik:latest
    container_name: traefik
    environment:
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
    ports:
      - "80:80"
      - "443:443"
    networks:
      - traefik-socket
    restart: unless-stopped

  traefik-docker-autonet:
    image: docker:cli
    volumes:
      - ./traefik-docker-autonet.sh:/app/traefik-docker-autonet.sh:ro
    environment:
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
      - NETWORK_SUFFIX=traefik-autonet
      - TRAEFIK_CONTAINER=traefik
    command: sh /app/traefik-docker-autonet.sh
    networks:
      - traefik-socket
    restart: never

  docker-socket-proxy:
    # See snippets below for Option A or B

networks:
  traefik-socket:
    driver: bridge
    internal: true
```

#### Option A: wollomatic/socket-proxy

More granular control with regex-based endpoint filtering and container whitelisting:

```yaml
docker-socket-proxy:
  image: wollomatic/socket-proxy:1
  container_name: docker-socket-proxy
  command:
    - '-loglevel=info'
    - '-allowfrom=traefik-docker-autonet'
    - '-allowfrom=traefik'
    - '-listenip=0.0.0.0'
    - '-allowGET=/v1\..{1,2}/(containers/.*|events.*|networks.*|version)'
    - '-allowPOST=/v1\..{1,2}/networks/.*/connect'
    - '-allowPOST=/v1\..{1,2}/networks/.*/disconnect'
    - '-allowPOST=/v1\..{1,2}/networks/create'
    - '-allowDELETE=/v1\..{1,2}/networks/.*'
    - '-stoponwatchchannel'
    - '-watchdeschedule'
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
  networks:
    - traefik-socket
  restart: unless-stopped
```

#### Option B: tecnativa/docker-socket-proxy

Simpler configuration with environment variable-based permissions:

```yaml
docker-socket-proxy:
  image: tecnativa/docker-socket-proxy
  container_name: docker-socket-proxy
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
  environment:
    CONTAINERS: 1
    NETWORKS: 1
    EVENTS: 1
    POST: 1
  networks:
    - traefik-socket
  restart: unless-stopped
```

### Application Container Example

Simply add the `traefik.enable=true` label to your containers:

```yaml
services:
  myapp:
    image: nginx
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`myapp.example.com`)
      - traefik.http.services.myapp.loadbalancer.server.port=80
```

**With Simplified Setup:**
The container will automatically be connected to the shared `reverse-proxy` network when created, and disconnected when destroyed.

**With Advanced Setup:**
The script will automatically:
1. Create a dedicated network named `myapp-traefik-autonet` with an isolated /30 subnet
2. Connect both `myapp` and `traefik` to this network
3. Clean up when `myapp` is destroyed

## Configuration

### Simplified Setup Environment Variables

- `REVERSE_PROXY_NETWORK`: The shared reverse proxy network name (default: `reverse-proxy`)
- `TRAEFIK_CONTAINER`: Name of the Traefik container (default: `traefik`)

### Advanced Setup Environment Variables

- `NETWORK_SUFFIX`: Suffix for auto-created networks (default: `traefik-autonet`)
- `AUTONET_SUBNET`: Subnet range for automatic /30 allocation (default: `172.30.0.0/16`)
- `TRAEFIK_CONTAINER`: Name of the Traefik container (default: `traefik`)

### Advanced Setup: Network Naming and Subnetting

Auto-created networks follow the pattern: `{container-name}-{NETWORK_SUFFIX}`

Example: `myapp-traefik-autonet` with subnet `172.30.0.0/30`

Each container gets its own /30 subnet automatically allocated from the `AUTONET_SUBNET` range, ensuring isolation and preventing network collisions.

## Behavior

### Simplified Setup

Containers labeled with `traefik.enable=true` are:
- Connected to the shared reverse proxy network on creation
- Disconnected from the network on destruction

### Advanced Setup: Network Creation Logic

The script creates an automatic isolated network only if:
- The container has `traefik.enable=true` label
- The container does NOT already share a network with Traefik
- A /30 subnet is available in the `AUTONET_SUBNET` range

If a container is already on a network accessible to Traefik, the script logs an informational message and skips automatic network creation.

### Advanced Setup: Network Cleanup

Networks are automatically removed when:
- The associated container is destroyed
- The script starts and finds orphaned networks from containers that no longer exist

## Security Considerations

**Simplified Setup:**
- Uses a shared network with Traefik (lower isolation)
- All labeled containers are on the same network as Traefik
- Suitable when containers are in the same trust domain

**Advanced Setup:**
- All auto-created networks are **internal** (no external connectivity)
- Each container gets an isolated /30 network
- Stronger isolation between containers
- Prevents network collisions across deployments

**For Both Setups:**
- Use docker-socket-proxy to limit Docker API access
- The script requires: `CONTAINERS`, `NETWORKS`, `EVENTS` permissions
- Advanced setup additionally requires `POST` and `DELETE` for network operations

## Logging

The script provides detailed logging for all operations:
- Container discovery
- Network creation/destruction
- Connection/disconnection events
- Warnings for existing shared networks
- Cleanup operations

## Limitations

- Only monitors containers with the `traefik.enable=true` label
- Assumes Traefik is running as a container (not as a system service)
- Requires Docker API access

## Notes

- No AI tools were harmed in the making of this tool... they were just used a little.

## License

MIT License - feel free to use and modify as needed.