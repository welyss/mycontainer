#!/bin/bash
set -eo pipefail
shopt -s nullglob

# if command starts with an option, prepend mysqld
if [ "${1:0:1}" = '-' ]; then
	set -- mysqld "$@"
fi

# skip setup if they want an option that stops mysqld
wantHelp=
for arg; do
	case "$arg" in
		-'?'|--help|--print-defaults|-V|--version)
			wantHelp=1
			break
			;;
	esac
done

# usage: file_env VAR [DEFAULT]
#    ie: file_env 'XYZ_DB_PASSWORD' 'example'
# (will allow for "$XYZ_DB_PASSWORD_FILE" to fill in the value of
#  "$XYZ_DB_PASSWORD" from a file, especially for Docker's secrets feature)
file_env() {
	local var="$1"
	local fileVar="${var}_FILE"
	local def="${2:-}"
	if [ "${!var:-}" ] && [ "${!fileVar:-}" ]; then
		echo >&2 "error: both $var and $fileVar are set (but are exclusive)"
		exit 1
	fi
	local val="$def"
	if [ "${!var:-}" ]; then
		val="${!var}"
	elif [ "${!fileVar:-}" ]; then
		val="$(< "${!fileVar}")"
	fi
	export "$var"="$val"
	unset "$fileVar"
}

# usage: process_init_file FILENAME MYSQLCOMMAND...
#    ie: process_init_file foo.sh mysql -uroot
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
	local f="$1"; shift
	local mysql=( "$@" )

	case "$f" in
		*.sh)     echo "$0: running $f"; . "$f" ;;
		*.sql)    echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
		*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
		*)        echo "$0: ignoring $f" ;;
	esac
	echo
}

_check_config() {
	toRun=( "$@" --verbose --help )
	if ! errors="$("${toRun[@]}" 2>&1 >/dev/null)"; then
		cat >&2 <<-EOM

			ERROR: mysqld failed while attempting to check config
			command was: "${toRun[*]}"

			$errors
		EOM
		exit 1
	fi
}

# Fetch value from server config
# We use mysqld --verbose --help instead of my_print_defaults because the
# latter only show values present in config files, and not server defaults
_get_config() {
	local conf="$1"; shift
	"$@" --verbose --help --log-bin-index="$(mktemp -u)" 2>/dev/null | awk '$1 == "'"$conf"'" { print $2; exit }'
}

# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
	_check_config "$@"
	DATADIR="$(_get_config 'datadir' "$@")"
	mkdir -p "$DATADIR"

	file_env 'MYSQL_ROOT_PASSWORD'
	file_env 'BACKUP_DOWNLOAD_FULL_URL'
	if [ -z "$MYSQL_ROOT_PASSWORD" -o -z "$BACKUP_DOWNLOAD_FULL_URL" ]; then
		echo >&2 'error: database is uninitialized and password option is not specified or backup download url is not specified.'
		echo >&2 '  You need to specify MYSQL_ROOT_PASSWORD and BACKUP_DOWNLOAD_FULL_URL'
		exit 1
	fi

	MEMORY="1G"
	if [ ! -z "$INNOBACKUPEX_MEMORY" ]; then
		MEMORY="$INNOBACKUPEX_MEMORY"
	fi
	INNOBACKUPEX=innobackupex
	backup_dir=/tmp/backups
	MY_CNF=/etc/mysql/my.cnf
	mkdir -p $backup_dir
	echo "===========>downloading fullbackup from: $BACKUP_DOWNLOAD_FULL_URL ......"
	result=$(curl "$BACKUP_DOWNLOAD_FULL_URL" -o $backup_dir/full.tar.gz -w %{http_code} 2>/dev/null)
	if [ $result = 200 ];then
		echo "===========>extracting $backup_dir/full.tar.gz" && mkdir -p "$backup_dir/full" && tar --no-same-owner -xzvf $backup_dir/full.tar.gz -C $backup_dir/full && rm -rf $backup_dir/full.tar.gz
		if [ -z "$BACKUP_DOWNLOAD_INC_URL" ];then
			echo "===========>increment url not exists."
		else
			echo "===========>downloading incrementbackup from: $BACKUP_DOWNLOAD_INC_URL ......"
			result=$(curl "$BACKUP_DOWNLOAD_INC_URL" -o $backup_dir/inc.tar.gz -w %{http_code} 2>/dev/null)
			if [ $result = 200 ];then
				#increment backup restore
				echo "===========>extracting $backup_dir/inc.tar.gz" && mkdir -p "$backup_dir/inc" && tar --no-same-owner -xzvf $backup_dir/inc.tar.gz -C $backup_dir/inc && rm -rf $backup_dir/inc.tar.gz
				echo 'increment restore:prepare full backup...........'
				chmod 646 -R $backup_dir/full
				if $INNOBACKUPEX --defaults-file=$MY_CNF --apply-log --redo-only --use-memory=$MEMORY $backup_dir/full;then
					INCRLAST=`ls -t $backup_dir/inc | head -1`
					for i in `find $backup_dir/inc -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -n `;
					do
						#lsn check
						check_full_lastlsn=$backup_dir/full/xtrabackup_checkpoints
						fetch_full_lastlsn=`grep -i "^last_lsn" ${check_full_lastlsn} |cut -d = -f 2`
						check_incre_lastlsn=$backup_dir/inc/$i/xtrabackup_checkpoints
						fetch_incre_lastlsn=`grep -i "^last_lsn" ${check_incre_lastlsn} |cut -d = -f 2`
						echo "===========>full-backup($check_full_lastlsn)LSN:${fetch_full_lastlsn} "
						echo "===========>increment-backup($check_incre_lastlsn)LSN:${fetch_incre_lastlsn} "
						if [ "${fetch_incre_lastlsn}" -eq "${fetch_full_lastlsn}" ];then
							echo "===========>LSN is newest."
							break
						else
							echo "===========>increment restore: prepare increment-restore $i........"
							chmod 646 -R $backup_dir/full && chmod 646 -R $backup_dir/inc/$i
							if [ $INCRLAST = $i ]; then
								# last one, except --redo-only option, --apply-log only.
								echo "===========>increment restore: process lastest increment backup."
								if $INNOBACKUPEX --defaults-file=$MY_CNF --apply-log --use-memory=$MEMORY $backup_dir/full --incremental-dir=$backup_dir/inc/$i;then
									break
								else
									echo >&2 "===========>increment restore:$i backup resotre faild."
									exit 1
								fi
							else
								# inc
								if ! $INNOBACKUPEX --defaults-file=$MY_CNF --apply-log --redo-only --use-memory=$MEMORY $backup_dir/full --incremental-dir=$backup_dir/inc/$i;then
									echo >&2 "===========>increment restore:$i backup resotre faild."
									exit 1
								fi
							fi
						fi
					done
				else
					echo >&2 'increment restore:full backup resotre faild.'
					exit 1
				fi
			else
				echo "===========>increment[$BACKUP_DOWNLOAD_INC_URL] not exists."
			fi
		fi

		#fullbackup restore
		if $INNOBACKUPEX --defaults-file=$MY_CNF --apply-log --use-memory=$MEMORY $backup_dir/full \
			&& $INNOBACKUPEX --defaults-file=$MY_CNF --move-back $backup_dir/full;then
			#cleanup
			echo "cleanup and chown directory to mysql."
			rm -rf $backup_dir
			chown mysql:mysql -R "$DATADIR"

			SOCKET="$(_get_config 'socket' "$@")"
			"$@" --skip-networking --skip-grant-tables --socket="${SOCKET}" --user=mysql &
			pid="$!"

			mysql=( mysql --protocol=socket -uroot -hlocalhost --socket="${SOCKET}" )
			for i in {30..0}; do
				if echo 'SELECT 1' | "${mysql[@]}" &> /dev/null; then
					break
				fi
				echo 'MySQL init process in progress...'
				sleep 1
			done
			if [ "$i" = 0 ]; then
				echo >&2 'MySQL init process failed.'
				exit 1
			fi

			"${mysql[@]}" <<-EOSQL
				-- initialize root user
				SET @@SESSION.SQL_LOG_BIN=0;
				FLUSH PRIVILEGES;
				GRANT ALL ON *.* TO 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION ;
				GRANT ALL ON *.* TO 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' WITH GRANT OPTION ;
				FLUSH PRIVILEGES;
			EOSQL

			echo
			ls /docker-entrypoint-initdb.d/ > /dev/null
			for f in /docker-entrypoint-initdb.d/*; do
				process_init_file "$f" "${mysql[@]}"
			done

			if ! kill -s TERM "$pid" || ! wait "$pid"; then
				echo >&2 'MySQL init process failed.'
				exit 1
			fi

			echo 'restore success.'
		else
			echo >&2 'restore faild.'
			exit 1
		fi
	else
		echo >&2 "fullbackup[$BACKUP_DOWNLOAD_FULL_URL] not exists."
		exit 1
	fi

	exec gosu mysql "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -un)" = 'mysql' ]; then
	# still need to check config, container may have started with --user
	_check_config "$@"

	echo
	echo 'MySQL init process done. Ready for start up.'
	echo
fi

exec "$@"
