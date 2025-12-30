# traefik-docker-autonet

Minimal shell-based container to automate connecting Traefik to containers.

## Overview

This project provides a lightweight Docker container that automatically manages network connectivity between Traefik and your application containers. When a container with the `traefik.enable=true` label starts, the script automatically creates a dedicated internal network and connects both the container and Traefik to it.

## Problem Statement

In Docker environments with Traefik as a reverse proxy, containers need to be on the same network as Traefik to be accessible. Manually managing these network connections becomes tedious, especially in dynamic environments where containers are frequently created and destroyed; moreover reusing a common reverse proxy network is not a best practice because that way containers are not isolated.

## Solution

This tool (script) monitors Docker events and automatically:

- Creates dedicated internal networks for each Traefik-enabled container
- Connects both the container and Traefik to these networks
- Cleans up networks when containers stop
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
2. **On container start**: Detects new containers with the label and creates networks automatically
3. **On container stop/die/destroy**: Disconnects Traefik and removes the dedicated network
4. **Continuous monitoring**: Watches Docker events stream for real-time updates, without polling

## Requirements

- Docker environment
- Traefik running as a container
- Access to Docker socket (directly or via docker-socket-proxy)

## Usage

### Setup with Local Script

Download the script locally and mount it as a volume in your docker-compose:

```bash
curl -o traefik-docker-autonet.sh https://raw.githubusercontent.com/psychowood/traefik-docker-autonet/main/traefik-docker-autonet.sh
chmod +x traefik-docker-autonet.sh
```

Then use it in your docker-compose.yml:

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
      - TRAEFIK_CONTAINER=traefik
    command: sh /app/traefik-docker-autonet.sh
    restart: unless-stopped
```

### With Docker Socket Proxy (Recommended)

For enhanced security, use a Docker socket proxy to limit Docker API access. Both `traefik` and `traefik-docker-autonet` should set `DOCKER_HOST=tcp://{proxy-service}:2375` and connect to the proxy network.

#### Option A: wollomatic/socket-proxy

More granular control with regex-based endpoint filtering and container whitelisting:

```yaml
socket-proxy:
  image: wollomatic/socket-proxy:1
  container_name: socket-proxy
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

The network manager will automatically:
1. Create a network named `myapp-traefik-autonet`
2. Connect both `myapp` and `traefik` to this network
3. Clean up when `myapp` stops

## Configuration

### Environment Variables

- `NETWORK_SUFFIX`: Suffix for auto-created networks (default: `traefik-autonet`)
- `TRAEFIK_CONTAINER`: Name of the Traefik container (default: `traefik`)

### Network Naming Convention

Auto-created networks follow the pattern: `{container-name}-{NETWORK_SUFFIX}`

Example: `myapp-traefik-autonet`

## Behavior

### Network Creation Logic

The script creates an automatic network only if:
- The container has `traefik.enable=true` label
- The container does NOT already share a network with Traefik

If a container is already on a network accessible to Traefik, the script logs an informational message and skips automatic network creation.

### Network Cleanup

Networks are automatically removed when:
- The associated container stops, dies, or is destroyed
- The script starts and finds orphaned networks from containers that no longer exist

## Security Considerations

- All auto-created networks are **internal** (no external connectivity)
- Use docker-socket-proxy to limit Docker API access
- The script only requires: `CONTAINERS`, `NETWORKS`, `EVENTS`, and `POST` permissions

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