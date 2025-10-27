#!/bin/bash
set -e
set -u

function create_user_and_database() {
	local database=$1
	echo "  Ensuring role and database exist for '$database'"

	# ensure role exists
	local role_exists=$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_roles WHERE rolname = '$database'")
	if [[ "$role_exists" != "1" ]]; then
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE USER $database;"
	fi

	# ensure database exists and owned by the role
	local db_exists=$(psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname = '$database'")
	if [[ "$db_exists" != "1" ]]; then
		psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE DATABASE $database OWNER $database;"
	fi

	psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "GRANT ALL PRIVILEGES ON DATABASE $database TO $database;"
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

function create_or_update_extra_users() {
	local enabled=${EXTRA_USERS_ENABLED:-}
	local users=${EXTRA_USERS:-}
	# Явное включение по флагу и наличие списка пользователей
	if [[ -z "$enabled" || "$enabled" == "0" || "$enabled" == "false" || -z "$users" ]]; then
		return
	fi

	echo "  Processing EXTRA_USERS to create/update roles"
	# Формат: user1:pass1,user2:pass2
	IFS=',' read -ra pairs <<< "$users"
	for pair in "${pairs[@]}"; do
		# Выделяем имя и пароль (пароль может быть пустым)
		local username="${pair%%:*}"
		local password="${pair#*:}"
		if [[ -z "$username" ]]; then
			continue
		fi
		if [[ -z "$password" ]]; then
			psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE USER $username;"
		else
			psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE USER $username WITH PASSWORD '$password';"
		fi
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

create_or_update_extra_users

# Ожидаем старта PostgreSQL перед применением настроек
sleep 10

# Путь к конфигурационному файлу PostgreSQL
PG_CONF="/var/lib/postgresql/data/postgresql.conf"

# Устанавливаем параметр deadlock_timeout
echo "deadlock_timeout = '5s'" >> "$PG_CONF"
