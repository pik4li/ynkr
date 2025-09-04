FROM alpine:latest

RUN apk add --no-cache curl yt-dlp ffmpeg busybox-suid bash python3 mutagen py3-requests py3-dotenv py3-pip

WORKDIR /app
COPY requirements.txt .

COPY download.sh .
COPY .src/* .

RUN chmod +x download.sh
RUN chmod +x run-import.sh

ARG PUID=1000
ARG PGID=1000

RUN addgroup --gid $PGID appuser
RUN adduser -g "" -D -u $PUID -G appuser appuser

# Install and configure cron
RUN echo "*/30 * * * * bash /app/run-import.sh" > /etc/crontabs/appuser
RUN chown -R appuser:appuser /app

# Install Python dependencies
USER appuser
RUN /app/run-import.sh init # initialize all the python dependencies on container build

# Start cron in the background when the container starts
ENTRYPOINT ["/bin/sh", "-c", "crond && exec /app/download.sh"]
