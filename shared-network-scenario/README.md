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
wget -O traefik-docker-autonet.sh https://raw.githubusercontent.com/psychowood/traefik-docker-autonet/refs/heads/main/shared-network-scenario/traefik-docker-autonet-simple.sh
chmod +x traefik-docker-autonet.sh
```

### 2. Configure Docker Compose

First, ensure your Traefik container is already connected to the existing shared network (e.g., `reverse-proxy`):

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
    command: sh /app/traefik-docker-autonet.sh
    restart: unless-stopped

  # Your application containers here
  myapp:
    image: nginx
    labels:
      - traefik.enable=true
      - traefik.http.routers.myapp.rule=Host(`myapp.example.com`)
      - traefik.http.services.myapp.loadbalancer.server.port=80
# The following is not needed anymore if using the script
#    networks:
#      - reverse-proxy
    restart: unless-stopped

networks:
  reverse-proxy:
    driver: bridge
```

### 3. How It Works

The script:
1. **On startup**: Connects all existing containers with `traefik.enable=true` label to the reverse proxy network
2. **On container creation/start**: Automatically connects containers with the `traefik.enable=true` label to the reverse proxy network.

## Configuration

### Environment Variables

- `REVERSE_PROXY_NETWORK`: Name of the shared reverse proxy network (default: `reverse-proxy`)
- `DOCKER_HOST`: Docker socket url, needed in case of a proxy or of a non standard install
- `RETRIES`: Number of attempts to retry connecting a container to the network on transient failures (default: `5`)
- `RETRY_DELAY`: Seconds to wait between retry attempts (default: `1`)

## Example: Adding a Container

Additionaly, if you configure some defaults on the `traefik.yml` static configuration:

```yaml
    providers:
      docker:    
        defaultRule: "Host(`{{ .ContainerName }}.mydomain`)"
        exposedByDefault: false
        network: reverse-proxy  
```

you can avoid declaring the external network at all in the container; simply add the `traefik.enable=true` label:

```yaml
services:
  myapi:
    image: mycompany/api:latest
    labels:
      - traefik.enable=true
```

and the container will be automatically connected to the `reverse-proxy` network.

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
    - '-listenip=0.0.0.0'
    - '-allowGET=/v1\..{1,2}/(containers/.*|events.*|version)'
    - '-allowPOST=/v1\..{1,2}/networks/.*/connect'
    - '-stoponwatchchannel'
    - '-watchdeschedule'
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
  networks:
    - traefik-socket
  restart: unless-stopped

traefik-docker-autonet:
  ...
  environment:
    - DOCKER_HOST=tcp://docker-socket-proxy:2375
    - REVERSE_PROXY_NETWORK=reverse-proxy
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

If you need per-container network isolation with automatic subnet allocation, use the advanced version in the parent directory (still WIP).

## License

MIT License
