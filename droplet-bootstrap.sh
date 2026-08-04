#!/usr/bin/env bash
set -euo pipefail

# bootstrap-droplet.sh (HTTPS-first clone)
# Usage: ./bootstrap-droplet.sh
# Prompts for required values and boots the MediaWiki + Traefik stack from your git repo.

# Configurable defaults
GIT_REPO="https://github.com/lynkfox/sentinelswiki.com.git"
TARGET_DIR="/opt/mediawiki"
USER_HOME="$HOME"

# helper
print() { printf '\n%s\n' "$1"; }

# Require sudo privilege for system-level commands
if ! command -v sudo >/dev/null 2>&1; then
  echo "sudo is required. Install sudo or run as root."
  exit 1
fi

print "1) Installing prerequisites (curl, git, ufw, etc.)"
sudo apt update
sudo apt install -y ca-certificates curl gnupg lsb-release apt-transport-https software-properties-common git ufw

print "2) Install Docker & Docker Compose plugin if missing"
if ! command -v docker >/dev/null 2>&1; then
  print "Installing Docker..."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu \
    $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt update
  sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
else
  print "Docker already installed"
fi

# Add user to docker group to avoid needing sudo for docker commands
if ! groups "$USER" | grep -qw docker; then
  print "Adding $USER to docker group (you may need to log out/login for group to take effect)"
  sudo usermod -aG docker "$USER"
  # try to refresh group in-process
  if command -v newgrp >/dev/null 2>&1; then
    newgrp docker <<'NG' || true
true
NG
  fi
fi

print "3) Clone repository into $TARGET_DIR (HTTPS)"
if [ -d "$TARGET_DIR/.git" ]; then
  print "Repository already cloned at $TARGET_DIR. Pulling latest..."
  cd "$TARGET_DIR"
  git fetch --all --prune
  git reset --hard origin/HEAD || true
else
  sudo mkdir -p "$TARGET_DIR"
  sudo chown "$USER":"$USER" "$TARGET_DIR"
  set +e
  git clone "$GIT_REPO" "$TARGET_DIR"
  CLONE_STATUS=$?
  set -e
  if [ $CLONE_STATUS -ne 0 ]; then
    echo
    echo "git clone over HTTPS failed. Common causes: private repo or network/authentication issue."
    read -rp "If the repo is private and you want to retry with a Personal Access Token (PAT), enter your GitHub username (or press Enter to abort): " GH_USER
    if [ -n "$GH_USER" ]; then
      read -rsp "Enter your GitHub Personal Access Token (PAT) (input hidden): " GH_PAT
      echo
      # Attempt authenticated HTTPS clone (credentials embedded temporarily)
      AUTH_URL="https://${GH_USER}:${GH_PAT}@github.com/lynkfox/sentinelswiki.com.git"
      set +e
      git clone "$AUTH_URL" "$TARGET_DIR"
      AUTH_CLONE_STATUS=$?
      set -e
      # Clear PAT variable from environment
      GH_PAT=""
      if [ $AUTH_CLONE_STATUS -ne 0 ]; then
        echo "Authenticated clone also failed. Aborting. Check credentials/permissions and network."
        exit 1
      else
        # Reset remote to canonical HTTPS URL (remove credentials)
        cd "$TARGET_DIR"
        git remote set-url origin "https://github.com/lynkfox/sentinelswiki.com.git"
        echo "Authenticated clone succeeded and remote URL was reset to non-auth HTTPS."
      fi
    else
      echo "Clone aborted. If you prefer SSH cloning, add the droplet SSH key to GitHub and re-run."
      exit 1
    fi
  else
    cd "$TARGET_DIR"
  fi
fi

print "Repository contents at $TARGET_DIR:"
ls -la "$TARGET_DIR" | sed -n '1,120p'

# If files missing, warn
if [ ! -f docker-compose.yml ]; then
  echo "WARNING: docker-compose.yml not found in repository. Ensure repo contains the compose + traefik files."
  ls -la
  read -rp "Continue anyway? (y/N): " cont || true
  if [[ "${cont:-N}" != "y" && "${cont:-N}" != "Y" ]]; then
    echo "Aborting; place docker-compose.yml into the repo and re-run."
    exit 1
  fi
fi

print "4) Prepare .env (secrets). If .env already exists, it will be left alone."
if [ -f .env ]; then
  echo ".env already present - skipped creation. Edit it manually if values are incorrect: $TARGET_DIR/.env"
else
  if [ -f .env.sample ]; then
    echo ".env.sample found. You can edit values interactively or copy .env.sample -> .env and edit."
    read -rp "Would you like to fill .env interactively now? (Y/n): " fill_choice || true
    fill_choice="${fill_choice:-Y}"
    if [[ "$fill_choice" =~ ^[Yy] ]]; then
      # Prompt interactively for required variables (sensitive inputs masked)
      read -rp "Domain (e.g. wiki.example.com): " DOMAIN
      read -rp "Let's Encrypt contact email: " LETSENCRYPT_EMAIL
      read -rp "Cloudflare API token (token requires DNS edit on your zone) (will be hidden): " -s CF_API_TOKEN
      echo
      read -rp "MySQL root password (hidden): " -s MYSQL_ROOT_PASSWORD
      echo
      read -rp "MySQL wiki password (hidden): " -s MYSQL_PASSWORD
      echo
      read -rp "MediaWiki admin password (hidden): " -s MEDIAWIKI_ADMIN_PASS
      echo
      read -rp "Dashboard admin IP (CIDR) to whitelist (e.g. 203.0.113.4/32): " DASHBOARD_ADMIN_IP

      cat > .env <<EOF
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
CF_API_TOKEN=${CF_API_TOKEN}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MEDIAWIKI_ADMIN_PASS=${MEDIAWIKI_ADMIN_PASS}
DASHBOARD_ADMIN_IP=${DASHBOARD_ADMIN_IP}
EOF
      chmod 600 .env
      echo ".env created at $TARGET_DIR/.env (permissions 600)"
    else
      cp .env.sample .env
      chmod 600 .env
      echo "Copied .env.sample -> .env. Edit $TARGET_DIR/.env with your real secrets and re-run."
      read -rp "Edit now with nano? (Y/n): " doedit || true
      doedit="${doedit:-Y}"
      if [[ "$doedit" =~ ^[Yy] ]]; then
        nano .env
      fi
    fi
  else
    echo "No .env.sample present. Creating interactive .env."
    read -rp "Domain (e.g. wiki.example.com): " DOMAIN
    read -rp "Let's Encrypt contact email: " LETSENCRYPT_EMAIL
    read -rp "Cloudflare API token (hidden): " -s CF_API_TOKEN
    echo
    read -rp "MySQL root password (hidden): " -s MYSQL_ROOT_PASSWORD
    echo
    read -rp "MySQL wiki password (hidden): " -s MYSQL_PASSWORD
    echo
    read -rp "MediaWiki admin password (hidden): " -s MEDIAWIKI_ADMIN_PASS
    echo
    read -rp "Dashboard admin IP (CIDR) to whitelist (e.g. 203.0.113.4/32): " DASHBOARD_ADMIN_IP

    cat > .env <<EOF
DOMAIN=${DOMAIN}
LETSENCRYPT_EMAIL=${LETSENCRYPT_EMAIL}
CF_API_TOKEN=${CF_API_TOKEN}
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
MYSQL_PASSWORD=${MYSQL_PASSWORD}
MEDIAWIKI_ADMIN_PASS=${MEDIAWIKI_ADMIN_PASS}
DASHBOARD_ADMIN_IP=${DASHBOARD_ADMIN_IP}
EOF
    chmod 600 .env
    echo ".env created at $TARGET_DIR/.env (permissions 600)"
  fi
fi

print "5) Ensure traefik/acme.json exists and has safe permissions (600)"
mkdir -p traefik
if [ ! -f traefik/acme.json ]; then
  touch traefik/acme.json
  chmod 600 traefik/acme.json
  echo "Created traefik/acme.json (permissions 600)"
else
  chmod 600 traefik/acme.json
  echo "traefik/acme.json present - permissions set to 600"
fi

print "6) Create data directories (db + images) if missing"
mkdir -p data/db data/images
chmod -R 700 data
ls -la data

print "7) Optional: Refresh Cloudflare IPs now (if refresh script exists)"
if [ -x traefik/refresh-cloudflare-ips.sh ]; then
  echo "Running traefik/refresh-cloudflare-ips.sh to update Cloudflare lists..."
  ./traefik/refresh-cloudflare-ips.sh || echo "refresh script returned nonzero (continue)"
else
  echo "No refresh script found at traefik/refresh-cloudflare-ips.sh - skipping"
fi

print "8) Start the stack with docker compose"
# If user still needs to log out/in for docker group, warn and allow sudo fallback
if groups "$USER" | grep -qw docker; then
  docker compose up -d traefik db mediawiki
else
  echo "Note: your user may not be in the docker group yet. Attempting docker compose with sudo."
  sudo docker compose up -d traefik db mediawiki
  echo "You should log out and log back in to apply docker group membership properly."
fi

print "9) Show Traefik logs to verify ACME progress (follow for a few minutes)"
if groups "$USER" | grep -qw docker; then
  docker compose logs -f traefik &
else
  sudo docker compose logs -f traefik &
fi

# UFW configuration
print "10) UFW firewall configuration (recommended)"
echo "We will allow OpenSSH, HTTP (80), HTTPS (443). The Traefik dashboard (8080) will be restricted to the DASHBOARD_ADMIN_IP value from .env."
read -rp "Apply UFW rules now? (Y/n): " applyufw || true
applyufw="${applyufw:-Y}"
if [[ "$applyufw" =~ ^[Yy] ]]; then
  # Read DASHBOARD_ADMIN_IP from .env
  DASH_IP=$(grep -E '^DASHBOARD_ADMIN_IP=' .env | cut -d'=' -f2- || true)
  sudo ufw allow OpenSSH
  sudo ufw allow 80/tcp
  sudo ufw allow 443/tcp
  if [ -n "$DASH_IP" ] && [ "$DASH_IP" != "REPLACE_ME" ]; then
    sudo ufw allow from "$DASH_IP" to any port 8080 proto tcp
    echo "Dashboard (8080) restricted to $DASH_IP"
  else
    echo "DASHBOARD_ADMIN_IP not set or left as placeholder; dashboard will not be restricted by UFW. Set DASHBOARD_ADMIN_IP in .env and add UFW rule manually."
  fi
  sudo ufw --force enable
  sudo ufw status verbose
else
  echo "Skipping UFW configuration. Remember to open ports 80 and 443 and restrict 8080 to your management IP."
fi

# Cron job for refresh
print "11) Install daily cron job to refresh Cloudflare IP list and restart Traefik (optional)"
if [ -x traefik/refresh-cloudflare-ips.sh ]; then
  read -rp "Install cron job to run refresh & restart Traefik daily at 03:05? (Y/n): " installcron || true
  installcron="${installcron:-Y}"
  if [[ "$installcron" =~ ^[Yy] ]]; then
    # add cron line for the current user
    CRON_CMD="cd $TARGET_DIR && ./traefik/refresh-cloudflare-ips.sh && docker compose restart traefik"
    (crontab -l 2>/dev/null | grep -Fv "$CRON_CMD" || true; echo "5 3 * * * $CRON_CMD") | crontab -
    echo "Cron installed (daily 03:05)."
  else
    echo "Skipping cron installation."
  fi
else
  echo "No refresh script found. Skipping cron install."
fi

print "Bootstrap complete."

echo
echo "Next steps & troubleshooting:"
echo "- Ensure DNS for DOMAIN points to this Droplet (A record)."
echo "- If certificates fail, check Traefik logs (docker compose logs -f traefik)."
echo "- If docker group change was made, log out and log back in before running docker without sudo."
echo "- To restore an existing MediaWiki backup: stop mediawiki, import DB dump into db container, restore images into data/images, then start mediawiki and run php maintenance/update.php."
echo
echo "Example restore commands (adjust paths):"
echo "  docker compose stop mediawiki"
echo "  docker compose exec -T db sh -c 'mysql -u root -p\"\$MYSQL_ROOT_PASSWORD\" mediawiki' < /path/to/backup.sql"
echo "  docker run --rm -v \$(pwd)/data/images:/var/www/html/images -v /path/to/backup:/backup alpine sh -c 'cd /var/www/html/images && tar xzf /backup/images.tar.gz'"
echo "  docker compose up -d mediawiki"
echo "  docker compose exec mediawiki php maintenance/update.php"

exit 0