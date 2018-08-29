#!/bin/bash
# Report Mysql Group Replication status to discovery service periodically.
# report_status.sh [mysql user] [mysql password] [cluster name] [interval] [comma separated discovery service hosts] [ipaddr]
# Example: 
# report_status.sh root myS3cret galera_cluster 15 192.168.55.111:2379,192.168.55.112:2379,192.168.55.113:2379 192.168.55.113

USER=$1
PASSWORD=$2
CLUSTER_NAME=$3
TTL=$4
DISCOVERY_SERVICE=$5
IPADDR=$6

function check_discovery_service()
{
	DISCOVERY_SERVICE=$(echo $DISCOVERY_SERVICE | tr ',' ' ')
	flag=1

	# Loop to find a healthy discovery service host
	for i in $DISCOVERY_SERVICE
	do
		curl -s http://$i/health > /dev/null || continue
		if curl -s http://$i/health | jq -e 'contains({ "health": "true"})' > /dev/null; then
			healthy_discovery=$i
			flag=0
			break
		fi
	done

	# Flag is 0 if there is a healthy discovery service host
	[ $flag -ne 0 ] && echo "report>> Couldn't reach healthy discovery service nodes."
}

function report_status()
{
	var=$1
	key=$2

	if [ ! -z $var ]; then
		check_discovery_service

		URL="http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/nodes"
		output=$(mysql --user=$USER --password=$PASSWORD -A -Bse "SELECT MEMBER_STATE FROM performance_schema.replication_group_members WHERE MEMBER_HOST = '$IPADDR'" 2> /dev/null)

		if [ ! -z $value ]; then
			curl -s $URL/$IPADDR -X PUT -d "value=$output&ttl=$TTL" > /dev/null
		fi
	fi
}

while true;
do
	report_status
	# report every ttl - 2 to ensure value does not expire
	sleep $(($TTL - 2))
done