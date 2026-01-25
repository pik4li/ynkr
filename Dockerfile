FROM alpine:latest

RUN apk update
RUN apk add --no-cache yt-dlp ffmpeg busybox-suid python3 mutagen

RUN apk add --no-cache bash sqlite jq curl chromaprint

WORKDIR /app
# COPY requirements.txt .
RUN mkdir downloads music db lib .cache

COPY ynkr.sh /app
COPY async-process.sh /app
COPY lib/* /app/lib/
COPY playlists /app

RUN chmod +x /app/ynkr.sh
# RUN chmod +x run-import.sh

ARG PUID=1000
ARG PGID=1000

RUN addgroup --gid $PGID appuser
RUN adduser -g "" -D -u $PUID -G appuser appuser

# Install and configure cron
# RUN echo "*/30 * * * * bash /app/run-import.sh" > /etc/crontabs/appuser
RUN chown -R appuser:appuser /app

# Install Python dependencies
USER appuser
# RUN /app/run-import.sh init # initialize all the python dependencies on container build

# Start cron in the background when the container starts
ENTRYPOINT ["/bin/bash", "-c", "/app/async-process.sh & /app/ynkr.sh"]
