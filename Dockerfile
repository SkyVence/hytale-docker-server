FROM eclipse-temurin:25-jdk AS base

LABEL java.version="25"

# Set environment variables for Java
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# Install necessary packages for networking and diagnostics
RUN apt-get update && apt-get install -y --no-install-recommends \
    dos2unix \
    wget \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Create a fixed machine-id for consistent hardware ID
RUN mkdir -p /var/lib/dbus \
    && echo "10000000100000001000000010000001" > /etc/machine-id \
    && ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Create non-root user for security (use different GID/UID to avoid conflicts)
RUN groupadd -g 1001 server \
    && useradd -u 1001 -g server -d /home/server -m server

# Create directories
RUN mkdir -p /app /server \
    && chown -R server:server /app /server

# Download hytale-downloader to /app (not affected by volume mount)
WORKDIR /app
RUN wget https://downloader.hytale.com/hytale-downloader.zip -O server-temp.zip \
    && unzip server-temp.zip -d server-temp \
    && cp server-temp/hytale-downloader-linux-amd64 ./hytale-downloader \
    && chmod +x ./hytale-downloader \
    && rm -rf server-temp server-temp.zip

# Copy entrypoint script to /app
COPY entrypoint.sh /app/entrypoint.sh
RUN dos2unix /app/entrypoint.sh \
    && chmod +x /app/entrypoint.sh

# Change ownership to server user
RUN chown -R server:server /app

# Volume for persistent server data
VOLUME [ "/server" ]


WORKDIR /server
EXPOSE 5520


# Switch to non-root user
USER server

ENTRYPOINT ["/app/entrypoint.sh"]
