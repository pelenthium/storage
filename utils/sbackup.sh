#!/bin/bash
#
# Script for do automatic backups files and dbs (mysql, pgsql)
# to Selectel Cloud Storage (http://selectel.ru/services/cloud-storage/)
#
# version: 1.1
#
# Authors:
# - Konstantin Kapustin <sirkonst@gmail.com>
#

# ------- Settings -------
# Selectel Storage settings
SS_USER=""  # Storage user
SS_PWD=""  # Storage password
SS_CONTAINER="backups"  # Storage container where we put backup files

# Backup settings
TARGET_DIR="/var/www/siterootdir"  # What to backup
#BACKUP_NAME="mysite"  # Name for backup, default the last folder name in target
BACKUP_NAME=`_t="${TARGET_DIR%/}" && echo "${_t##*/}"`
BACKUP_DIR="/var/backups/$BACKUP_NAME"  # Where our backup will be placed
EXCLUDE_LIST="\
*~
*.bak
*.old
*.log
.git/
.svn/
"
# SQL backup settings
DB_TYPE="mysql" # (mysql:pgsql)
DB_NAME="site_db_name"  # Database name, set __ALL__ for backup all dbs or empty for disable backup
DB_USER="site_user"
DB_PWD="site_user_pwd"
DB_HOST="localhost"
DB_PORT="3306" # Usually 3306 for MySQL and 5432 for PostgreSQL

EMAIL="admin@site.test"  # Email for send log, set empty if don't want seng log
EMAIL_ONLY_ON_ERROR="no"  # Send a email only if there was something strange (yes:no) 

DELETE_LOG="yes"  # remove log when finished? (yes:no)
DELETE_BACKUPS_AFTER_UPLOAD="no"  # remove backups files after successful upload to Storage (yes:no)
# How long store backup in the Storage (in days)? If you set 30, uploaded file will be auto removed after 30 days.
STORAGE_EXPIRE=""

# ------- Utils -------
SUPLOAD=`which supload`
# or set path manual
#SUPLOAD="/usr/local/bin/supload"
MYSQLDUMP=`which mysqldump`
PGDUMP=`which pg_dump`
BZIP=`which bzip2`
TAR=`which tar`
SENDMAIL=`which sendmail`

# ------- Checking -------
if [ -z "$SS_USER" ] || [ -z "$SS_PWD" ] || [ -z "$SS_CONTAINER" ]; then
	echo "[!] Please set Selectel Storage settings first!"
	exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
	echo "[!] Backup's target doesn't exist $TARGET_DIR!"
	exit 1
fi

if [ ! -d "$BACKUP_DIR" ]; then
	mkdir "$BACKUP_DIR"
	if [ $? -ne 0 ]; then
		echo "[!] Can not create backup dir $BACKUP_DIR!"
		exit 1
	fi
fi

if [ -n "$EMAIL" ] && [ -z "$SENDMAIL" ]; then
	echo "[!] sendmail is not installed!"
	exit 1
fi

if [ -n "$STORAGE_EXPIRE" ]; then
	if [ "$STORAGE_EXPIRE" -eq "$STORAGE_EXPIRE" ] 2>/dev/null; then
		:
	else
		echo "[!] STORAGE_EXPIRE must be a positive integer!"
		exit 1
	fi
fi

# ------- Preparation -------
TIMESTAMP=$(date +%Y-%m-%d_%Hh%Mm)
BACKUP_FILENAME="${BACKUP_NAME}_$TIMESTAMP.tar.bz2"
LOG_FILE="$BACKUP_DIR/log_$BACKUP_NAME-$TIMESTAMP.log"
declare -a _for_upload

if [ x"$DB_NAME" = "x__ALL__" ]; then
	DB_BACKUP_FILENAME="${DB_TYPE}_${BACKUP_NAME}_ALL_$TIMESTAMP.sql"
	DB_NAME=""
else
	if [ -z "$DB_NAME" ]; then
		DB_BACKUP_FILENAME=""
	else
		DB_BACKUP_FILENAME="${DB_TYPE}_${BACKUP_NAME}_${DB_NAME}_$TIMESTAMP.sql"
	fi
fi

if [ -n "$DB_BACKUP_FILENAME" ] && [ "$DB_TYPE" = "mysql" ] && [ -z "$MYSQLDUMP" ]; then
	echo "[!] mysqldump is not installed!"
	exit 1
fi

if [ -n "$DB_BACKUP_FILENAME" ] && [ "$DB_TYPE" = "pgsql" ] && [ -z "$PGDUMP" ]; then
	echo "[!] pg_dump is not installed!"
	exit 1
fi

# detect interective mode
if [[ -t 1 ]]; then
	IM="1"                
else
	IM="0"                    
fi

set -o pipefail
_log() {
	while read line; do
		if [ x"$IM" == x"1" ]; then
			echo "$line" | tee -a "$LOG_FILE"
		else
			echo "$line" >> "$LOG_FILE"
		fi
	done
}

_error="0"

echo "$(date +%H:%M:%S) Begin backup $BACKUP_NAME" | _log

# ------- Backup files -------
echo "$(date +%H:%M:%S) Archiving files $TARGET_DIR" | _log
tar_exc=""
for line in ${EXCLUDE_LIST}; do
	tar_exc="$tar_exc --exclude '$line'"
done
cd "$TARGET_DIR/.."
_target=`expr match "${TARGET_DIR%%/}" '.*/\(.*\)'`
$TAR cjpf "$BACKUP_DIR/$BACKUP_FILENAME" ${tar_exc} "$_target" > /dev/null 2>&1 | _log

files_size=$(du -h "$BACKUP_DIR/$BACKUP_FILENAME" | cut -f1)
echo "$(date +%H:%M:%S) Files backup put to $BACKUP_DIR/$BACKUP_FILENAME ($files_size)" | _log 

_for_upload=( "${_for_upload[@]}" "$BACKUP_DIR/$BACKUP_FILENAME")

# ------- Backup databases -------
if [ -n "$DB_BACKUP_FILENAME" ]; then
	# Create database dump
	echo "$(date +%H:%M:%S) Creating DB dump for ${DB_NAME:-ALL dbs}" | _log

	if [ "$DB_TYPE" = "mysql" ]; then
		$MYSQLDUMP --opt -u "$DB_USER" -p"$DB_PWD" -h "$DB_HOST" -P "$DB_PORT" "${DB_NAME:---all-databases}" > "$BACKUP_DIR/$DB_BACKUP_FILENAME"
	fi
	if [ "$DB_TYPE" = "pgsql" ]; then
		PGPASSWORD="$DB_PWD" $PGDUMP -U "$DB_USER" -h "$DB_HOST" -p "$DB_PORT" -F p -f "$BACKUP_DIR/$DB_BACKUP_FILENAME" "$DB_NAME"
	fi

	$BZIP -9 --force "$BACKUP_DIR/$DB_BACKUP_FILENAME"
	DB_BACKUP_FILENAME="$DB_BACKUP_FILENAME.bz2"

	db_size=$(du -h "$BACKUP_DIR/$DB_BACKUP_FILENAME" | cut -f1)
	echo "$(date +%H:%M:%S) Database backup put to $BACKUP_DIR/$DB_BACKUP_FILENAME ($db_size)" | _log

	_for_upload=( "${_for_upload[@]}" "$BACKUP_DIR/$DB_BACKUP_FILENAME")
fi

# ------- Upload backups -------
echo "$(date +%H:%M:%S) Uploading backup files to Selectel Storage..." | _log

for _file in "${_for_upload[@]}"; do
	_u_opts=""
	if [ -n "$STORAGE_EXPIRE" ]; then
		_u_opts="-d ${STORAGE_EXPIRE}d"
	fi
	$SUPLOAD -u "$SS_USER" -k "$SS_PWD" $_u_opts "$SS_CONTAINER" "$_file" | _log
	if [ $? -ne 0 ]; then
		_error="1"
	else
		if [ x"$DELETE_BACKUPS_AFTER_UPLOAD" = x"yes" ]; then
			rm -f "$_file"
			echo "$(date +%H:%M:%S) File $_file was removed" | _log
		fi
	fi
done

# ------- Clearing and notification -------
if [ x"$_error" = x"0" ]; then
	echo "$(date +%H:%M:%S) Backup complete, have a nice day!" | _log
	_title="[Backup log] $BACKUP_NAME ($TIMESTAMP)"
else
	echo "$(date +%H:%M:%S) Backup complete with errors, see log $LOG_FILE." | _log
	_title="[Backup log - !ERRORS!] $BACKUP_NAME ($TIMESTAMP)"
fi

if [ -n "$SENDMAIL" ] && [ -n "$EMAIL" ]; then
	if [ x"$_error" = x"0" ] && [ x"$EMAIL_ONLY_ON_ERROR" = x"yes" ]; then
		:
	else
		cat - "$LOG_FILE" << EOF | $SENDMAIL -t
To:$EMAIL
Subject:$_title

EOF
	fi
fi

if [ x"$DELETE_LOG" = x"yes" ] && [ x"$_error" = x"0" ]; then
	rm -f "$LOG_FILE"  # Delete log file
fi
