#!/bin/bash
set -e

echo "=========================================="
echo "  Pawly Backend - Supabase Self-Hosted"
echo "=========================================="

# ── Docker kurulumu ──
if ! command -v docker &> /dev/null; then
  echo "[1/6] Docker kuruluyor..."
  apt-get update -qq
  apt-get install -y ca-certificates curl gnupg lsb-release git
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
  systemctl start docker
  echo "[1/6] Docker kuruldu."
else
  echo "[1/6] Docker zaten kurulu: $(docker --version)"
fi

# ── Supabase docker dosyaları ──
echo "[2/6] Supabase Docker Compose indiriliyor..."
mkdir -p /opt/supabase
cd /opt/supabase

if [ ! -f docker-compose.yml ]; then
  curl -fsSL https://raw.githubusercontent.com/supabase/supabase/master/docker/docker-compose.yml -o docker-compose.yml
fi
if [ ! -f .env ]; then
  curl -fsSL https://raw.githubusercontent.com/supabase/supabase/master/docker/.env.example -o .env
  echo "[2/6] .env.example indirildi, yapılandırılıyor..."
fi

# ── .env yapılandırma ──
echo "[3/6] .env yapılandırılıyor..."

JWT_SECRET="pawly-super-secret-jwt-token-2026-MhmMtn"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoiYW5vbiIsImlhdCI6MTYxMzUzMTk4NSwiZXhwIjo0NzY5MTA3OTg1fQ.HkQitLVNHN0k3JWlkLuYNxHaHaIqRvWkZyZlpKxBPJA"
SERVICE_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJyb2xlIjoic2VydmljZV9yb2xlIiwiaWF0IjoxNjEzNTMxOTg1LCJleHAiOjQ3NjkxMDc5ODV9.TobVzTmNzSHk1hMFPSSTGrVqpxd3PFcT6x0jVrJgWXU"
POSTGRES_PASS="PawlyDB_MhmMtn2026!"
DASHBOARD_PASS="PawlyDash_2026!"
SERVER_IP="23.88.56.175"

sed -i "s|POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASS}|g" .env
sed -i "s|JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|g" .env
sed -i "s|ANON_KEY=.*|ANON_KEY=${ANON_KEY}|g" .env
sed -i "s|SERVICE_ROLE_KEY=.*|SERVICE_ROLE_KEY=${SERVICE_KEY}|g" .env
sed -i "s|SITE_URL=.*|SITE_URL=http://${SERVER_IP}:8000|g" .env
sed -i "s|API_EXTERNAL_URL=.*|API_EXTERNAL_URL=http://${SERVER_IP}:8000|g" .env
sed -i "s|SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=http://${SERVER_IP}:8000|g" .env
sed -i "s|DASHBOARD_USERNAME=.*|DASHBOARD_USERNAME=admin|g" .env
sed -i "s|DASHBOARD_PASSWORD=.*|DASHBOARD_PASSWORD=${DASHBOARD_PASS}|g" .env

echo "[3/6] .env yapılandırıldı."

# ── Servisleri başlat ──
echo "[4/6] Supabase servisleri başlatılıyor... (ilk seferinde ~3 dakika sürer)"
cd /opt/supabase
docker compose pull
docker compose up -d

echo "[4/6] Servisler ayağa kaldırıldı, PostgreSQL hazır olana kadar bekleniyor..."
sleep 45

# ── Pawly repo'su ──
echo "[5/6] Pawly BE reposu çekiliyor..."
mkdir -p /opt/pawly_be
cd /opt/pawly_be

if [ -d ".git" ]; then
  git pull origin master
else
  git clone https://github.com/mmetinn/pawly_be.git .
fi

# ── Migrationlar ──
echo "[6/6] Migration'lar çalıştırılıyor..."
PGPASSWORD="${POSTGRES_PASS}" psql \
  -h localhost -p 5432 \
  -U postgres \
  -d postgres \
  --set ON_ERROR_STOP=off \
  -f <(cat /opt/pawly_be/migrations/*.sql) 2>&1 | tail -20

echo ""
echo "=========================================="
echo "  KURULUM TAMAMLANDI!"
echo "=========================================="
echo ""
echo "  Supabase Studio : http://${SERVER_IP}:8000"
echo "  API URL         : http://${SERVER_IP}:8000"
echo "  Dashboard User  : admin"
echo "  Dashboard Pass  : ${DASHBOARD_PASS}"
echo ""
echo "  ANON KEY:"
echo "  ${ANON_KEY}"
echo ""
echo "  SERVICE KEY:"
echo "  ${SERVICE_KEY}"
echo ""
echo "  UI .env.local için:"
echo "  EXPO_PUBLIC_SUPABASE_URL=http://${SERVER_IP}:8000"
echo "  EXPO_PUBLIC_SUPABASE_ANON_KEY=${ANON_KEY}"
echo "=========================================="
