#!/bin/bash
# Report Mysql Group Replication status for health.

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
	[ $flag -ne 0 ] && echo "$(date +'%Y-%m-%d %R:%S') health>> Couldn't reach healthy discovery service nodes."
}

check_discovery_service

if [ ! -z "$healthy_discovery" ]; then
	URL="http://$healthy_discovery/v2/keys/mysql/$CLUSTER_NAME/nodes"
	HOST=$(hostname)
	health=$(curl -s "$URL/$HOST.${CLUSTER_NAME}-srv"|jq -r '.node|select(.value=="ONLINE").key')
	if [[ "$health" != "" ]];then
		exit 0
	fi
fi

exit 1