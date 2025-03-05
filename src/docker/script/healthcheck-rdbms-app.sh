#!/bin/sh
if docker logs rdbms-app 2>&1 | tail -n 20 | grep -q "HikariPool-1 - Shutdown completed."; then
  echo "Database connection pool shutdown detected! Marking as unhealthy."
  exit 1
else
  echo "Service running normally."
  exit 0
fi