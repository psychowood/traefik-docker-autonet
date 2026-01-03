# Simplified Shared Network Scenario

This folder contains the simplified version of traefik-docker-autonet for use cases where all traefik-enabled containers connect to a single shared reverse proxy network.

## When to Use This

- You want the simplest possible setup
- All your containers are in the same trust domain
- You don't need per-container network isolation
- You prefer minimal overhead and configuration

## Setup

### 1. Download the Script

```bash
wget -O traefik-docker-autonet.sh traefik-docker-autonet-simple.sh
chmod +x traefik-docker-autonet.sh
```

### 2. Configure Docker Compose

First, ensure your Traefik container is connected to a network (e.g., `reverse-proxy`):

```yaml
version: '3.8'

services:
  traefik:
    image: traefik:latest
    container_name: traefik
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "80:80"
      - "443:443"
    networks:
      - reverse-proxy
    restart: unless-stopped

  traefik-docker-autonet:
    image: docker:cli
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./traefik-docker-autonet.sh:/app/traefik-docker-autonet.sh:ro
    environment:
      - REVERSE_PROXY_NETWORK=reverse-proxy
      - TRAEFIK_CONTAINER=traefik
    command: sh /app/traefik-docker-autonet.sh
    networks:
      - reverse-proxy
    restart: unless-stopped

  # Your application containers here
  myapp:
    image: nginx
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`myapp.example.com`)
      - traefik.http.services.myapp.loadbalancer.server.port=80
    networks:
      - reverse-proxy
    restart: unless-stopped

networks:
  reverse-proxy:
    driver: bridge
```

### 3. How It Works

The script:
1. **On startup**: Connects all existing containers with `traefik.enable=true` label to the reverse proxy network
2. **On container creation**: Automatically connects the new container to the reverse proxy network
3. **On container destruction**: Disconnects the container from the network

## Configuration

### Environment Variables

- `REVERSE_PROXY_NETWORK`: Name of the shared reverse proxy network (default: `reverse-proxy`)
- `TRAEFIK_CONTAINER`: Name of the Traefik container (default: `traefik`)

## Example: Adding a Container

Simply add the `traefik.enable=true` label:

```yaml
services:
  myapi:
    image: mycompany/api:latest
    labels:
      - traefik.enable=true
```

The container will be automatically connected to the `reverse-proxy` network.

## With Docker Socket Proxy (Recommended)

For enhanced security, use a Docker socket proxy:

### Option A: wollomatic/socket-proxy

```yaml
socket-proxy:
  image: wollomatic/socket-proxy:1
  container_name: docker-socket-proxy
  command:
    - '-loglevel=info'
    - '-allowfrom=traefik-docker-autonet'
    - '-allowfrom=traefik'
    - '-listenip=0.0.0.0'
    - '-allowGET=/v1\..{1,2}/(containers/.*|events.*|version)'
    - '-allowPOST=/v1\..{1,2}/networks/.*/connect'
    - '-allowPOST=/v1\..{1,2}/networks/.*/disconnect'
    - '-stoponwatchchannel'
    - '-watchdeschedule'
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
  networks:
    - traefik-socket
  restart: unless-stopped

traefik:
  environment:
    - DOCKER_HOST=tcp://docker-socket-proxy:2375
  networks:
    - traefik-socket

traefik-docker-autonet:
  environment:
    - DOCKER_HOST=tcp://docker-socket-proxy:2375
    - REVERSE_PROXY_NETWORK=reverse-proxy
    - TRAEFIK_CONTAINER=traefik
  networks:
    - traefik-socket
```

### Option B: tecnativa/docker-socket-proxy

```yaml
socket-proxy:
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

## Limitations

- All containers share the same network as Traefik (no per-container isolation)
- Containers need to be able to resolve each other by hostname
- Network policy rules affect all containers equally

## For Advanced Isolation

If you need per-container network isolation with automatic subnet allocation, use the advanced version in the parent directory.

## License

MIT License
