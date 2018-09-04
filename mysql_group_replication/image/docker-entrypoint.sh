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
	local online=""
	while [ -z $online ];do
		online=$(curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/nodes"|jq -r '.node.nodes[]|select(.value=="ONLINE").key'|sed 's/.*\///g')
		sleep 1
	done
	echo $online|awk '{for(i=1;i<=NF;i++){ips=ips$i":33061";if(i<NF) ips=ips",";} print ips}'
}

# allow the container to be started with `--user`
if [ "$1" = 'mysqld' -a -z "$wantHelp" -a "$(id -u)" = '0' ]; then
		_check_config "$@"
		DATADIR="$(_get_config 'datadir' "$@")"
		mkdir -p "$DATADIR"
		chown -R mysql:mysql "$DATADIR"
		chown -R mysql:mysql /etc/mysql
		exec gosu mysql "$BASH_SOURCE" "$@"
fi

if [ "$1" = 'mysqld' -a -z "$wantHelp" ]; then
		if [ -z "$MYSQL_ROOT_PASSWORD" -o -z "$CLUSTER_NAME" -o -z "$DISCOVERY_SERVICE" ]; then
				echo >&2 '  You need to specify all of MYSQL_ROOT_PASSWORD, CLUSTER_NAME and DISCOVERY_SERVICE'
				exit 1
		fi

		if [ -z "$MYSQL_REPL_PASSWORD" ];then
			MYSQL_REPL_PASSWORD=$MYSQL_ROOT_PASSWORD
		fi

		repluser="repl"
		[ -z "$TTL" ] && TTL=10

		# still need to check config, container may have started with --user
		_check_config "$@"

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

		echo "!includedir /etc/mysql/mysql.conf.d/" > /etc/mysql/my.cnf
		ipaddr=$(hostname -i | awk {'print $1'})
		serverid=$(($(echo "$(echo $ipaddr|sed 's/\.//g')%4294967295")))
		# initailize group replication options
		cat >/etc/mysql/mysql.conf.d/group_replication.cnf<<-EOF
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

		# Get config
		DATADIR="$(_get_config 'datadir' "$@")"
		if [ ! -d "$DATADIR/mysql" ]; then

				mkdir -p "$DATADIR"

				echo 'Initializing database'
				"$@" --initialize-insecure
				echo 'Database initialized'

				SOCKET="$(_get_config 'socket' "$@")"
				"$@" --skip-networking --socket="${SOCKET}" &
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

				if [ -z "$MYSQL_INITDB_SKIP_TZINFO" ]; then
						# sed is for https://bugs.mysql.com/bug.php?id=20545
						mysql_tzinfo_to_sql /usr/share/zoneinfo | sed 's/Local time zone must be set--see zic manual page/FCTY/' | "${mysql[@]}" mysql
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
						read -r -d '' rootCreate <<-EOSQL || true
								CREATE USER 'root'@'${MYSQL_ROOT_HOST}' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
								GRANT ALL ON *.* TO 'root'@'${MYSQL_ROOT_HOST}' WITH GRANT OPTION ;
						EOSQL
				fi

				"${mysql[@]}" <<-EOSQL
						-- What's done in this file shouldn't be replicated
						--  or products like mysql-fabric won't work
						SET @@SESSION.SQL_LOG_BIN=0;

						SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
						GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;
						${rootCreate}
						DROP DATABASE IF EXISTS test ;
						CREATE USER 'rpl_user'@'%' IDENTIFIED BY '${MYSQL_REPL_PASSWORD}';
						GRANT REPLICATION SLAVE ON *.* TO 'rpl_user'@'%';
						FLUSH PRIVILEGES ;
						CHANGE MASTER TO MASTER_USER='rpl_user', MASTER_PASSWORD='${MYSQL_REPL_PASSWORD}' FOR CHANNEL 'group_replication_recovery';
						INSTALL PLUGIN group_replication SONAME 'group_replication.so';
				EOSQL

				if [ ! -z "$MYSQL_ROOT_PASSWORD" ]; then
						mysql+=( -p"${MYSQL_ROOT_PASSWORD}" )
				fi

				if [ "$MYSQL_DATABASE" ]; then
						echo "CREATE DATABASE IF NOT EXISTS \`$MYSQL_DATABASE\` ;" | "${mysql[@]}"
						mysql+=( "$MYSQL_DATABASE" )
				fi

				if [ "$MYSQL_USER" -a "$MYSQL_PASSWORD" ]; then
						echo "CREATE USER '$MYSQL_USER'@'%' IDENTIFIED BY '$MYSQL_PASSWORD' ;" | "${mysql[@]}"

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
		fi

		# check bootstrap_group
		isbootstrap=$(curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/bootstrap?prevExist=false" -XPUT -d value=$ipaddr|jq -r '.node.value')
		if [ "$isbootstrap" = null ];then
			# cluster exists, find servers
			isbootstrap=$(curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/bootstrap"|jq -r '.node.value')
			# check $isbootstrap alive
			if ping -c 5 $isbootstrap && [ "$isbootstrap" != "$ipaddr" ];then
				echo 'cluster exists and alive.'
				online=$(_waiting_for_ready)
				bootstrapgroup="off"
			else
				isbootstrap=$(curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/bootstrap?prevValue=$isbootstrap" -XDELETE|jq -r '.node.key')
				if [ "$isbootstrap" = null ];then
					echo 'cluster exists and dead, delete old isbootstrap faild, we need waiting for others.'
					bootstrapgroup="off"
					online=$(_waiting_for_ready)
				else
					echo 'cluster exists and dead, delete old isbootstrap success, we will start as new bootstrap.'
					curl -s "http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/bootstrap?prevExist=false" -XPUT -d value=$ipaddr
					bootstrapgroup="on"
				fi
			fi
		else
			# this is a new cluster
			echo 'this is a new cluster.'
			bootstrapgroup="on"
		fi

		if [ "$bootstrapgroup" = "on" ];then
			online="$ipaddr:33061"
		fi

		# initailize group replication options
		cat >>/etc/mysql/mysql.conf.d/group_replication.cnf<<-EOF
			gtid_mode=on
			enforce_gtid_consistency=on
			transaction_write_set_extraction=XXHASH64
			group_replication_local_address="$ipaddr:33061"
			group_replication_group_seeds="$online"
			group_replication_start_on_boot=on
			group_replication_bootstrap_group=$bootstrapgroup
			report_host=$ipaddr
		EOF

		cat >>/etc/mysql/mysql.conf.d/group_replication.cnf<<-EOF
			expire_logs_days=3
			group_replication_group_name="70155729-a504-11e8-9740-00ff8601922c"
			group_replication_single_primary_mode=off
			group_replication_enforce_update_everywhere_checks=on

			#Group Replication Requirements optimize
			slave_parallel_workers=8
			slave_preserve_commit_order=1
			slave_parallel_type=LOGICAL_CLOCK
			binlog_transaction_dependency_tracking=WRITESET_SESSION
			sync_binlog=0
			binlog_group_commit_sync_delay=50000

			#Group Replication Limitations optimize
			transaction_isolation=READ-COMMITTED
		EOF

		echo >&2 ">> Starting reporting script in the background"
		echo "====>/report_status.sh root $MYSQL_ROOT_PASSWORD $CLUSTER_NAME $TTL $DISCOVERY_SERVICE $ipaddr"
		/report_status.sh root $MYSQL_ROOT_PASSWORD $CLUSTER_NAME $TTL $DISCOVERY_SERVICE $ipaddr &

		echo
		echo 'MySQL init process done. Ready for start up.'
		echo
fi

exec "$@"