#!/bin/bash
set -e

echo "=== 🚀 EC2 Infra Bootstrap (Script Version) started at $(date) ==="

##############################
# 1) Basic package setup
##############################
echo "Updating apt and installing base packages..."
sudo apt-get update -y
sudo apt-get install -y curl gnupg2 ca-certificates lsb-release apt-transport-https build-essential python3 python3-venv python3-pip git postgresql postgresql-contrib nginx nodejs npm

##############################
# 2) Ensure PostgreSQL service and cluster
##############################
echo "Ensuring PostgreSQL service and cluster..."
PG_VERSION=$(psql --version | grep -oP '\d+' | head -1)
PG_VERSION=${PG_VERSION:-14}

if ! sudo pg_lsclusters | grep -q "$PG_VERSION[[:space:]]\+main"; then
  echo "No cluster found for $PG_VERSION, creating..."
  sudo pg_createcluster "$PG_VERSION" main --start
else
  echo "Cluster for PostgreSQL $PG_VERSION exists."
fi

sudo systemctl enable postgresql
sudo systemctl start postgresql

echo "Waiting up to 60 seconds for PostgreSQL service and socket..."
for i in {1..60}; do
  if sudo systemctl is-active --quiet postgresql && sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
    echo "✓ PostgreSQL is up (attempt $i)"
    break
  fi
  sleep 1
done

##############################
# 3) Configure PostgreSQL DB and user
##############################
echo "Configuring PostgreSQL database and user..."

if sudo -u postgres psql -c "SELECT 1" >/dev/null 2>&1; then
  if ! sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw ring; then
    sudo -u postgres createdb ring
    echo "✓ Database 'ring' created"
  else
    echo "✓ Database 'ring' already exists"
  fi

  sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='postgres';" | grep -q 1 && \
    sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD 'postgres';"
  echo "✓ Password set for postgres user"

  sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ring TO postgres;"
  sudo -u postgres psql -c "ALTER USER postgres CREATEDB;"
else
  echo "❌ ERROR: PostgreSQL not responding, skipping DB/user creation."
fi

##############################
# 4) Tune PostgreSQL config
##############################
echo "Tuning PostgreSQL configs..."
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
HBA_CONF="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

if [ -f "$PG_CONF" ]; then
  sudo sed -i "s/^#\?listen_addresses =.*/listen_addresses = 'localhost'/" "$PG_CONF"
  sudo sed -i "s/^#\?max_connections =.*/max_connections = 100/" "$PG_CONF"
  sudo sed -i "s/^#\?shared_buffers =.*/shared_buffers = 256MB/" "$PG_CONF"
fi

if [ -f "$HBA_CONF" ]; then
  sudo cp "$HBA_CONF" "${HBA_CONF}.backup.$(date +%Y%m%d)"
  sudo grep -q "^local.*all.*postgres.*md5" "$HBA_CONF" || echo "local   all   postgres   md5" | sudo tee -a "$HBA_CONF"
  sudo grep -q "^local.*all.*all.*md5" "$HBA_CONF" || echo "local   all   all   md5" | sudo tee -a "$HBA_CONF"
fi

sudo systemctl restart postgresql

##############################
# 5) Prepare app directories
##############################
echo "Creating app directories..."
sudo mkdir -p /var/www/Elden-ATS/Frontend-ATS /var/www/Elden-ATS/Backend-ATS
sudo chown -R ubuntu:ubuntu /var/www/Elden-ATS
sudo chmod -R 755 /var/www/Elden-ATS

##############################
# 6) Create Nginx config
##############################
NGINX_SITE="/etc/nginx/sites-available/elden-ats"
if [ ! -f "$NGINX_SITE" ]; then
  sudo tee "$NGINX_SITE" > /dev/null <<NGINXEOF
server {
    listen 80;
    server_name _;
    root /var/www/Elden-ATS/Frontend-ATS/dist;
    index index.html;
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    location /backend/ {
        rewrite ^/backend/?(.*)\$ /\$1 break;
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
    error_page 500 502 503 504 /50x.html;
    location = /50x.html { root /usr/share/nginx/html; }
}
NGINXEOF
  sudo ln -sf "$NGINX_SITE" /etc/nginx/sites-enabled/elden-ats
  sudo rm -f /etc/nginx/sites-enabled/default
  sudo nginx -t && sudo systemctl restart nginx
fi

##############################
# 7) Python venv + FastAPI backend systemd service
##############################
BACKEND_DIR="/var/www/Elden-ATS/Backend-ATS"
VENV_DIR="$BACKEND_DIR/.venv"
if [ ! -d "$VENV_DIR" ]; then
  sudo -u ubuntu python3 -m venv "$VENV_DIR"
fi

SERVICE_FILE="/etc/systemd/system/ats-backend.service"
if [ ! -f "$SERVICE_FILE" ]; then
  sudo tee "$SERVICE_FILE" > /dev/null <<SERVICEEOF
[Unit]
Description=ATS FastAPI backend (uvicorn)
After=network.target postgresql.service
Wants=postgresql.service
[Service]
User=ubuntu
Group=www-data
WorkingDirectory=$BACKEND_DIR
Environment="PATH=$VENV_DIR/bin"
Environment="PYTHONUNBUFFERED=1"
ExecStart=$VENV_DIR/bin/uvicorn app.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
SERVICEEOF
  sudo systemctl daemon-reload
  sudo systemctl enable ats-backend
fi

##############################
# 8) Firewall with UFW
##############################
if command -v ufw >/dev/null 2>&1; then
  sudo ufw allow 'Nginx Full' || true
  sudo ufw allow OpenSSH || true
  sudo ufw --force enable || true
fi

##############################
# 9) Final summary/status
##############################
echo ""
echo "=== ✅ EC2 Infra Bootstrap Completed Successfully ==="
echo ""
echo "📊 Installation Summary:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🌐 Nginx:        $(nginx -v 2>&1)"
echo "🟢 Node.js:      $(node -v)"
echo "🐍 Python:       $(python3 --version)"
echo "🐘 PostgreSQL:   $(psql --version)"
echo "📦 Git:          $(git --version)"
echo ""
echo "📁 Directories:"
echo "   Frontend:     /var/www/Elden-ATS/Frontend-ATS/"
echo "   Backend:      /var/www/Elden-ATS/Backend-ATS/"
echo ""
echo "🗄️  Database:"
echo "   Database:     ring"
echo "   User:         postgres"
echo "   Password:     postgres"
echo "   Host:         localhost"
echo "   Port:         5432"
echo ""
echo "🔧 Services Status:"
sudo systemctl is-active nginx && echo "   ✓ Nginx:      Running" || echo "   ✗ Nginx:      Stopped"
sudo systemctl is-active postgresql && echo "   ✓ PostgreSQL: Running" || echo "   ✗ PostgreSQL: Stopped"
sudo systemctl is-enabled ats-backend && echo "   ✓ Backend:    Enabled (not started yet)" || echo "   ✗ Backend:    Not enabled"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Infrastructure setup complete!"
echo "==================================================="
