## ynkr

---

It's a youtube audio grabber. Easy to setup, private via VPNs (if you want it
to)..

### **Setup/Installation**

**Preperations**

> [!CAUTION]
> If you are on an ARM based system, there is currently no automatic build
> process for it. So you have to [build your own image](#building-the-container-for-arm-based-systems))

- Youtube playlists marked at least as `not listed`
- Docker/-compose
  > [!NOTE]
  > only if you want to download more private..
  >
  > - get gluetun up and running

You ~need~ (you technically don't **need** a gluetun config, or any other VPN, but i would highly recommend it for security and privacy reasons) a gluetun configuration which works for you. I have a Cyberghost subscription, where i can then get the login data for gluetun, so that the main connections come from a differnt country/different public IP.

```yml
services:
  ynkr:
    image: ynkr:latest
    environment:
      - PUID=1000        # Replace with your actual UID (your own id)
      - PGID=1000         # Replace with your actual GID (the docker group)
    volumes:
      - ./downloads:/downloads # this is the raw music/download folder -> playlists same as in source
      - ./music:/music # this is the processed music folder - would highly recommend setting up a jellyfin instance/container, which points to this exact folder path
      - ./music_imports.db:/app/music_imports.db:rw # <- in this database file, we will store and keep track of the processed data, so that we dont need to generate too much ai requests.
      - ./archives:/archives # <- for keeping track of yt-dlp's already downloaded tracks
      - ./playlists:/app/playlists:ro # <- to let yt-dlp know what to download
    restart: unless-stopped
    network_mode: service:proxy # <-- here you acctually tell the docker socket, to use gluetun network for the ynkr app!!
    depends_on:
      - proxy

  proxy:
    image: docker.io/qmcgaw/gluetun:latest
    container_name: proxy
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=<provider>
      - OPENVPN_USER=<user>
      - OPENVPN_PASSWORD=<password>
      - TZ=Europe/Berlin
      # - SERVER_COUNTRIES=Spain
    volumes:
      - ./gluetun:/gluetun # <-- you have to put in your certificates in there!!
```

You then have to make sure the directories and files exist

```bash
mkdir archives music downloads
touch playlists music_imports.db
```

> You can also link the folders to different places, doesn't have to be in the
> current working directory.
> You can do something like:
> ```yml title="compose.yml"
> volumes:
>     - /mnt/downloads:/downloads
>     - /mnt/music:/music
> ```

Fill in the `playlists` file like this..

```ini title="playlists.env"
<name> = <youtube-playlist-url>

# like this..
example = https://music.youtube.com/playlist?list=PLzXB9N9Lp6mXs8CHGAyMndCQdHWZS5aPR&si=3EJP2wEwB5oy63UF
```

The script checks for the `=` limiter charakter, fill in as much playlists as you like. It will auto create folders with the `name` and **download** the **audiofiles**, **thumnails** and other **meta** **data** into the mapped folder via `<folder>:/downloads`

### Building the Container (for ARM-based systems)

If you're using an ARM-based system like Raspberry Pi, you'll need to build the container yourself:

1. Clone the repository:
   ```bash
   git clone https://github.com/pik4li/ynkr.git
   cd ynkr
   ```

2. Build the Docker image:
   ```bash
   docker build -t ynkr:latest .
   ```

3. Update your `compose.yml` file to use the locally built image:
```yml
services:
  ynkr:
    image: ynkr:latest  # Change to your local image:tag
    # ... rest of the configuration remains the same
```
