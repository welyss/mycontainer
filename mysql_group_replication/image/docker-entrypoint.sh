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

# usage: process_init_file FILENAME MYSQLCOMMAND...
#	ie: process_init_file foo.sh mysql -uroot
# (process a single initializer file, based on its extension. we define this
# function here, so that initializer scripts (*.sh) can use the same logic,
# potentially recursively, or override the logic used in subsequent calls)
process_init_file() {
	local f="$1"; shift
	local mysql=( "$@" )

	case "$f" in
		*.sh)	 echo "$0: running $f"; . "$f" ;;
		*.sql)	echo "$0: running $f"; "${mysql[@]}" < "$f"; echo ;;
		*.sql.gz) echo "$0: running $f"; gunzip -c "$f" | "${mysql[@]}"; echo ;;
		*)		echo "$0: ignoring $f" ;;
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

_waiting_for_ready() {
	local timeout=$1
	local online=""
	local index=0
	while [ -z $online ];do
		if [[ -n $timeout && $index -ge $timeout ]];then
			return
		fi
		nodes=$(curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/nodes"|jq -r '.node.nodes')
		if [[ "$nodes" != null ]];then
			online=$(echo "$nodes"|jq -r '.[]|select(.value=="ONLINE").key'|sed 's/.*\///g')
		fi
		sleep 1
		((index+=1))
	done
	echo $online
}

[ -z "$TTL" ] && TTL=10
host=$(hostname)
if [ -z $SERVICE_NAME ];then
	SERVICE_NAME=mysql-gr
fi

# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
	if [ -z "$CLUSTER_NAME" -o -z "$DISCOVERY_SERVICE" ]; then
		echo >&2 '  You need to specify all of CLUSTER_NAME and DISCOVERY_SERVICE'
		exit 1
	fi

	repluser="repl"

	echo '>> Registering in the discovery service'
	discovery_hosts=$(echo $DISCOVERY_SERVICE | tr ',' ' ')
	flag=1
	echo
	# Loop to find a healthy discovery service host
	for i in $discovery_hosts
	do
		echo ">> Connecting to http://${i}/health"
		curl -s http://${i}/health || continue
		if curl -s http://$i/health | jq -e 'contains({ "health": "true"})'; then
			healthy_discovery=$i
			flag=0
			break
		else
			echo >&2 ">> Node $i is unhealty. Proceed to the next node."
		fi
	done
	# Flag is 0 if there is a healthy discovery service host
	if [ $flag -ne 0 ]; then
		echo ">> Couldn't reach healthy discovery service nodes."
		exit 1
	fi

	[[ `hostname` =~ -([0-9]+)$ ]] || exit 1
	serverid=$((${BASH_REMATCH[1]}+100))

	# initailize group replication options
	cat >>/etc/mysql/mysql.conf.d/group_replication.cnf<<-EOF
		[mysqld]
		#Group Replication Requirements
		server_id=$serverid
		master_info_repository=TABLE
		relay_log_info_repository=TABLE
		binlog_checksum=none
		log_slave_updates=on
		log_bin=binlog
		relay_log=relay-bin
		binlog_format=row
	EOF

	myuuid=$(cat /proc/sys/kernel/random/uuid)
	# elect leader
	# wait for all of heath check finished.
	sleep $TTL
	online=$(_waiting_for_ready 1)
	if [ -z $online ];then
		echo 'No online nodes, need to create cluster.'
		if ! curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/uuid" -XPUT -d value=$myuuid; then
			echo 'set uuid faild, create cluster faild.'
			exit 1
		fi
		bootstrapgroup="on"
		uuid=$myuuid
	else
		echo 'online exists, joining to online nodes.'
		seeds=$(echo "$online"|awk '{for(i=1;i<=NF;i++){hosts=hosts$i".'$SERVICE_NAME':33061";if(i<NF) hosts=hosts",";} print hosts}')
		bootstrapgroup="off"
		uuid=$(curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/uuid"|jq -r '.node.value')
	fi

	# set group replication options
	cat >>/etc/mysql/mysql.conf.d/group_replication.cnf<<-EOF
		gtid_mode=on
		enforce_gtid_consistency=on
		transaction_write_set_extraction=XXHASH64
		loose-group_replication_group_name=$uuid
		loose-group_replication_local_address=$host.$SERVICE_NAME:33061
		loose-group_replication_group_seeds=$seeds
		loose-group_replication_bootstrap_group=$bootstrapgroup
		loose-group_replication_start_on_boot=off
		report_host=$host.$SERVICE_NAME
	EOF

	# Initializing datadir
	DATADIR="$(_get_config 'datadir' "$@")"
	mkdir -p "$DATADIR"
	if [ ! -d "$DATADIR/mysql" ]; then
		if [ "$bootstrapgroup" = "on" ];then
			echo 'Initializing database'
			"$@" --initialize-insecure
			echo 'Database initialized'
		else
			# Clone data from previous peer.
			peer=$(echo "$online"|awk '{for(i=1;i<=NF;i++){hosts=hosts$i".'$SERVICE_NAME'";if(i<NF) hosts=hosts",";} print hosts}')
			echo "fetching data from $peer"
			ncat --recv-only $peer 3307 | xbstream -x -C $DATADIR
			# Prepare the backup.
			echo 'preparing data with xtrabackup'
			xtrabackup --prepare --target-dir=$DATADIR
			# check binlog pos
			read -r -d '' initDatabase <<-EOSQL || true
				RESET MASTER;RESET SLAVE ALL;
				RESET SLAVE ALL FOR CHANNEL 'group_replication_recovery';
				RESET SLAVE ALL FOR CHANNEL 'group_replication_applier';
			EOSQL
			if [[ -f $DATADIR/xtrabackup_slave_info ]]; then
				setPosition=$(cat $DATADIR/xtrabackup_slave_info|head -1)
			fi
			if [[ -z "$setPosition" && -f $DATADIR/xtrabackup_binlog_info ]]; then
				setPosition=$(echo "SET GLOBAL gtid_purged='$(cat $DATADIR/xtrabackup_binlog_info|sed 's/.*\s\+//g')';")
			fi
		fi
	else
		echo 'datadir exists'
		ls -al $DATADIR
	fi

	chown -R mysql:mysql "$DATADIR"
	chown -R mysql:mysql /etc/mysql/mysql.conf.d/group_replication.cnf

	echo '==== group_replication.cnf start ===='
	cat /etc/mysql/mysql.conf.d/group_replication.cnf
	echo '==== group_replication.cnf end ===='
	_check_config "$@"

	# Initializing database
	SOCKET="$(_get_config 'socket' "$@")"
	"$@" --skip-networking --skip-grant-tables --socket="${SOCKET}" --user=mysql &
	pid="$!"

	mysql=( mysql --protocol=socket -uroot --socket="${SOCKET}" )

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

	if [ ! -z "$MYSQL_RANDOM_ROOT_PASSWORD" ]; then
		export MYSQL_ROOT_PASSWORD="$(pwgen -1 32)"
		echo "GENERATED ROOT PASSWORD: $MYSQL_ROOT_PASSWORD"
	fi

	rootCreate=
	# default root to listen for connections from anywhere
	if [ ! -z "$MYSQL_ROOT_HOST" -a "$MYSQL_ROOT_HOST" != 'localhost' ]; then
		# no, we don't care if read finds a terminating character in this heredoc
		# https://unix.stackexchange.com/questions/265149/why-is-set-o-errexit-breaking-this-read-heredoc-expression/265151#265151
		if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
			read -r -d '' rootCreate <<-EOSQL || true
				DROP USER IF EXISTS 'root'@'${MYSQL_ROOT_HOST}';CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
				GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
			EOSQL
		fi
	fi

	echo "executing sql script [rootCreate]:$rootCreate"
	echo "executing sql script [initDatabase]:$initDatabase"
	echo "executing sql script [setPosition]:$setPosition"

	"${mysql[@]}" <<-EOSQL
		-- What's done in this file shouldn't be replicated
		--  or products like mysql-fabric won't work
		SET @@SESSION.SQL_LOG_BIN=0;

		FLUSH PRIVILEGES;
		DROP USER IF EXISTS 'root'@'localhost';CREATE USER 'root'@'localhost';
		GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
		${rootCreate}
		DROP USER IF EXISTS 'rpl_user'@'%';CREATE USER 'rpl_user'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
		GRANT REPLICATION SLAVE ON *.* TO 'rpl_user'@'%';
		FLUSH PRIVILEGES ;
		${initDatabase}
		CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='${MYSQL_REPL_PASSWORD}' FOR CHANNEL 'group_replication_recovery';
		${setPosition}
	EOSQL

	if [ "$MYSQL_DATABASE" ]; then
		echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
		mysql+=( "$MYSQL_DATABASE" )
	fi

	if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
		echo "DROP USER IF EXISTS '$MYSQL_USER'@'%';CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

		if [ "$MYSQL_DATABASE" ]; then
			echo "GRANT ALL ON \`$MYSQL_DATABASE\`.* TO '$MYSQL_USER'@'%' ;" | "${mysql[@]}"
		fi

		echo 'FLUSH PRIVILEGES ;' | "${mysql[@]}"
	fi

	echo
	ls /docker-entrypoint-initdb.d/ > /dev/null
	for f in /docker-entrypoint-initdb.d/*; do
		process_init_file "$f" "${mysql[@]}"
	done

	if [ ! -z "$MYSQL_ONETIME_PASSWORD" ]; then
		"${mysql[@]}" <<-EOSQL
			ALTER USER 'root'@'%' PASSWORD EXPIRE;
		EOSQL
	fi
	if ! kill -s TERM "$pid" || ! wait "$pid"; then
		echo >&2 'MySQL init process failed.'
		exit 1
	fi

	echo >&2 ">> Starting reporting script in the background"
	echo "====>/report_status.sh $SOCKET $CLUSTER_NAME $TTL $DISCOVERY_SERVICE $host $SERVICE_NAME"
	/report_status.sh $SOCKET $CLUSTER_NAME $TTL $DISCOVERY_SERVICE $host $SERVICE_NAME &

	echo >&2 ">> Starting ncat send server in the background on port 3307"
	ncat --listen --keep-open --send-only --max-conns=1 3307 -c \
		"innobackupex --backup --slave-info --stream=xbstream --socket="${SOCKET}" --user=root /tmp" &

	echo
	echo 'MySQL init process done. Ready for start up.'
	echo

	exec gosu mysql "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -un)" = 'mysql' ]; then
	echo 'starting mysqld as mysql'
fi

exec "$@"
