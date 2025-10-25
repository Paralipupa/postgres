#!/bin/bash
set -e
set -u

function create_user_and_database() {
	local database=$1
	echo "  Creating user and database '$database'"
	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
	    CREATE USER $database;
	    CREATE DATABASE $database;
	    GRANT ALL PRIVILEGES ON DATABASE $database TO $database;
EOSQL
}

function create_or_update_web_user() {
    local username=${WEB_USER:-postgres}
    local password=${WEB_PASSWORD:-password}
    local user_exists=$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$username'")
    if [[ "$user_exists" != "1" ]]; then
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
            CREATE USER $username WITH PASSWORD '$password';
EOSQL
    else
        psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "ALTER USER $username WITH PASSWORD '$password';"
    fi
}

function grant_privileges_to_web_user() {
	local username=${WEB_USER:-postgres}
	local databases=$1
	for db in $(echo $databases | tr ',' ' '); do
		echo "  Granting privileges on database '$db' to user '$username'"
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" <<-EOSQL
		    GRANT ALL PRIVILEGES ON DATABASE $db TO $username;
EOSQL
	done
}

create_or_update_web_user

if [ -n "${POSTGRES_MULTIPLE_DATABASES:-}" ]; then
	echo "Multiple database creation requested: $POSTGRES_MULTIPLE_DATABASES"
	for db in $(echo $POSTGRES_MULTIPLE_DATABASES | tr ',' ' '); do
		create_user_and_database $db
	done
	echo "Multiple databases created"
	grant_privileges_to_web_user "$POSTGRES_MULTIPLE_DATABASES"
fi

# Ожидаем старта PostgreSQL перед применением настроек
sleep 10

# Путь к конфигурационному файлу PostgreSQL
PG_CONF="/var/lib/postgresql/data/postgresql.conf"

# Устанавливаем параметр deadlock_timeout
echo "deadlock_timeout = '5s'" >> "$PG_CONF"
