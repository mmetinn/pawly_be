#!/bin/bash
set -e

echo "[BE] Pawly repo güncelleniyor..."
cd /opt/pawly_be
git pull origin master

echo "[BE] Yeni migration'lar uygulanıyor..."
PGPASSWORD="PawlyDB_MhmMtn2026!" psql \
  -h localhost -p 5432 \
  -U postgres \
  -d postgres \
  --set ON_ERROR_STOP=off \
  -f <(cat /opt/pawly_be/migrations/*.sql) 2>&1 | tail -10

echo "[BE] Güncelleme tamamlandı."
