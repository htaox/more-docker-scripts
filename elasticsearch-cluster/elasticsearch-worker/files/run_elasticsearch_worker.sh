#!/bin/bash

env

echo 'Starting Elasticsearch Worker'

IP=$(ip -o -4 addr list eth0 | perl -n -e 'if (m{inet\s([\d\.]+)\/\d+\s}xms) { print $1 }')
echo "WORKER_IP=$IP"

sed -i "s/@IP@/$IP/g" $ES_HOME/conf/elasticsearch.yml
#sed -i "s|^network.host:.*|network.host: $IP|" $ES_HOME/conf/elasticsearch.yml

sed -i "s/@MASTER@/false/g" $ES_HOME/conf/elasticsearch.yml
sed -i "s/@DATA@/true/g" $ES_HOME/conf/elasticsearch.yml

#elasticsearch requires hostname loopback
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost ${HOSTNAME}/" /etc/hosts

ES_HEAP_SIZE=2g

sudo -u elasticsearch $ES_HOME/bin/elasticsearch -f -Des.config=$ES_HOME/conf/elasticsearch.yml -Xms$ES_HEAP_SIZE -Xmx$ES_HEAP_SIZE
