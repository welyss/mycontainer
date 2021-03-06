#!/bin/bash
# Report Mysql Group Replication status to discovery service periodically.
# report_status.sh [mysql socket] [cluster name] [interval] [comma separated discovery service hosts] [HOST]
# Example: 
# report_status.sh /var/lib/mysql/socket galera_cluster 15 192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 192.168.55.113

SOCKET=$1
CLUSTER_NAME=$2
TTL=$3
DISCOVERY_SERVICE=$4
HOST=$5
SERVICE_NAME=$6

function check_discovery_service()
{
	DISCOVERY_SERVICE=$(echo $DISCOVERY_SERVICE | tr ',' ' ')
	flag=1

	# Loop to find a healthy discovery service host
	for i in $DISCOVERY_SERVICE
	do
		if curl -s http://$i/health | jq -e 'contains({ "health": "true"})' > /dev/null; then
			healthy_discovery=$i
			flag=0
			break
		fi
	done

	# Flag is 0 if there is a healthy discovery service host
	[ $flag -ne 0 ] && echo "$(date +'%Y-%m-%d %R:%S') report>> Couldn't reach healthy discovery service nodes."
}

function report_status()
{
	check_discovery_service
	if [ -z $healthy_discovery ];then
		echo "[$healthy_discovery] invaild."
	else
		URL="http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/nodes"
		output=$(mysql --user=root -S$SOCKET -A -Bse "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST = '$HOST.$SERVICE_NAME'" 2> /dev/null)
		if [ ! -z $output ]; then
			curl -s "$URL/$HOST.$SERVICE_NAME" -XPUT -d value=$output -d ttl=$TTL > /dev/null
		fi
	fi
}

while true;
do
	if mysql --user=root -S$SOCKET -e "SELECT 1" 2> /dev/null; then
		mysql --user=root -S$SOCKET -e "START GROUP_REPLICATION" && break
	fi
	sleep 1
done

while true;
do
	report_status
	# report every ttl - 2 to ensure value does not expire
	sleep $(($TTL - 2))
done
