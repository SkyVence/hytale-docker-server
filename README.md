# Hytale Server — Quick Usage

Simple instructions to run the Hytale server using the pre-built image or Docker Compose.

Prerequisites
- Docker
- (Optional) Docker Compose or the `docker compose` plugin

Run the published image
```sh
# start the container (uses GHCR image)
docker run -d \
  --name hytale-server \
  -p 5520:5520/udp \
  -v "$(pwd)/server-data:/server" \
  -v "$(pwd)/credentials.json:/server/credentials.json:ro" \
  -e CREDENTIALS_FILE=credentials.json \
  ghcr.io/skyvence/hytale-server:latest
```

Run with Docker Compose
```sh
# starts the service defined in docker-compose.yml
docker compose up -d
# or (legacy)
docker-compose up -d
```

Build and run locally
```sh
# build locally (replace <your-owner> with your GHCR owner or desired name)
docker build -t ghcr.io/<your-owner>/hytale-server:local .
docker run -d --name hytale-server -p 5520:5520/udp \
  -v "$(pwd)/server-data:/server" \
  -v "$(pwd)/credentials.json:/server/credentials.json:ro" \
  -e CREDENTIALS_FILE=credentials.json \
  ghcr.io/<your-owner>/hytale-server:local
```

Notes
- The server listens on UDP port 5520.
- Ensure `credentials.json` exists and contains valid credentials (it is mounted read-only in compose).
