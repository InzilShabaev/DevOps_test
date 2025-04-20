#!/bin/bash

# Проверка параметров
if [ -z "$1" ]; then
    echo "Ошибка: необходимо передать IP-адреса или хостнеймы серверов через запятую"
    exit 1
fi

# Разделяем строку на массив и проверяем число аргументов
IFS=',' read -ra SERVERS <<< "$1"
if [ "${#SERVERS[@]}" -ne 2 ]; then
    echo "Ошибка: должно быть ровно два сервера"
    exit 1
fi

SERVER1="${SERVERS[0]}"
SERVER2="${SERVERS[1]}"
SSH_USER="root"
SSH_KEY="$HOME/.ssh/id_rsa"

# Версия PostgreSQL
echo "Какую версию PostgreSQL будем устанавливать? Введите мажорный номер: "
read PG_VERSION

# Оцениваем нагрузку на сервер параметром load average, оценивая количество активных заданий за минуту

echo "Оцениваем загрузку серверов..."

load1=$(ssh -i "$SSH_KEY" "$SSH_USER@$SERVER1" "uptime | awk -F'load average: ' '{ print \$2 }' | cut -d',' -f1")
load2=$(ssh -i "$SSH_KEY" "$SSH_USER@$SERVER2" "uptime | awk -F'load average: ' '{ print \$2 }' | cut -d',' -f1")

echo "$SERVER1: загрузка $load1"
echo "$SERVER2: загрузка $load2"

# Установка дополнительной утилиты bc
apt update & apt install -y bc

# Выбор сервера с меньшей нагрузкой
if (( $(echo "$load1 < $load2" | bc -l) )); then
    TARGET="$SERVER1"
    OTHER="$SERVER2"
else
    TARGET="$SERVER2"
    OTHER="$SERVER1"
fi

echo "Целевой сервер: $TARGET"

# Преобразование имен серверов в IP

TARGET=$(getent hosts "$TARGET" | awk '{ print $1 }' | head -n 1)
OTHER=$(getent hosts "$OTHER" | awk '{ print $1 }' | head -n 1)

# Установка PostgreSQL
echo "Устанавливаем PostgreSQL"

ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" bash -s << EOF

if [ -f /etc/debian_version ]; then
	echo "Обновляем систему и устанавливаем нужные пакеты..."
	apt update
	apt install -y wget gnupg2 lsb-release ca-certificates
elif [ -f /etc/redhat-release ]; then
    echo "Обновляем систему и устанавливаем зависимости..."
	dnf update -y
	dnf install -y dnf-utils curl
fi
EOF

DISTR_CODENAME=$(ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" 'lsb_release -cs')
DISTR_NUMBER=$(ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" 'rpm -E %{rhel}')

ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" bash -s << EOF

if [ -f /etc/debian_version ]; then
	echo "Добавляем репозиторий PostgreSQL $PG_VERSION в /etc/apt/sources.list.d/pgdg.list..."
	echo "deb [signed-by=/etc/apt/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $DISTR_CODENAME-pgdg main" | tee /etc/apt/sources.list.d/pgdg.list > /dev/null
	
	echo "Импортируем GPG-ключ PostgreSQL $PG_VERSION..."
	mkdir -p /etc/apt/keyrings
	wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor | tee /etc/apt/keyrings/postgresql.gpg > /dev/null

	echo "Обновляем пакеты..."
	apt update

	echo "Устанавливаем PostgreSQL $PG_VERSION..."
	apt install -y postgresql-$PG_VERSION postgresql-client-$PG_VERSION

	echo "Включаем и запускаем службу PostgreSQL $PG_VERSION..."
	systemctl enable postgresql
	systemctl start postgresql
elif [ -f /etc/redhat-release ]; then
	echo "Добавляем репозиторий PostgreSQL $PG_VERSION..."
	dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-$DISTR_NUMBER-x86_64/pgdg-redhat-repo-latest.noarch.rpm
	
	echo "Устанавливаем PostgreSQL $PG_VERSION..."
	dnf install -y postgresql$PG_VERSION-server postgresql$PG_VERSION
	
	echo "Инициализируем базу данных..."
	/usr/pgsql-$PG_VERSION/bin/postgresql-$PG_VERSION-setup initdb
	
	echo "Включаем и запускаем службу PostgreSQL..."
	systemctl enable postgresql-$PG_VERSION
	systemctl start postgresql-$PG_VERSION
fi
EOF

echo "PostgreSQL установлен"

# Конфигурация PostgreSQL
echo "Настраиваем PostgreSQL"

# Определение PG конфигов
PG_HBA=$(ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" 'sudo -u postgres psql -t -P format=unaligned -c "SHOW hba_file;"')
PG_CONF=$(ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" 'sudo -u postgres psql -t -P format=unaligned -c "SHOW config_file;"')

# Настройка подключений
ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" bash -s << EOF

# Настройка прослушивания всех интерфейсов
sed -i "s/^#listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"

# Настройка доступа для пользователя "student" только с IP второго сервера
echo "host    all             student         $OTHER/32           md5" >> "$PG_HBA"

EOF

# Рестарт сервиса PostgreSQL
ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" bash -s << EOF
if [ -f /etc/debian_version ]; then
        systemctl restart "postgresql"
elif [ -f /etc/redhat-release ]; then
        systemctl restart "postgresql-$PG_VERSION"
fi
EOF

echo "Настройка завершена"

echo "Проверяем соединение и выполнение запроса SELECT 1"

ssh -i "$SSH_KEY" "$SSH_USER@$TARGET" bash -s <<'EOF'
sudo -u postgres psql -c "SELECT 1;"

if [ $? -eq 0 ]; then
echo "Проверка работы БД завершена успешно"
else
echo "Проверка работы БД завершена с ошибкой"
fi

EOF

exit 0