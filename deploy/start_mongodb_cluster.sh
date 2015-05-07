#!/bin/bash

# Docker interface ip
#DOCKERIP="10.1.42.1"

BASEDIR=$(cd $(dirname $0); pwd)

declare -A hostmap

function initiateReplicatSets() {

  for i in `seq 1 $NUM_WORKERS`; do

    # sleep 10 # Wait for mongo to start
    # Setup replica set
    echo "Initiating replicat set"
    #docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" $NAMESERVER_IP:$(docker port mongos${i}r1 27017|cut -d ":" -f2) /root/jsfiles/initiate.js" htaox/mongodb-worker:3.0.2
    docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" ${hostmap["mongos${i}r1"]}:27017/local /root/jsfiles/initiate.js" htaox/mongodb-worker:3.0.2
    echo "Waiting for set to be initiated..."
    sleep 10

    #update setupReplicaSet.js
    echo "Updating replicat set"
    #docker run --dns $NAMESERVER_IP -P -i -t -e WORKERNUM=${i} -e OPTIONS=" $NAMESERVER_IP:$(docker port mongos${i}r1 27017|cut -d ":" -f2) /root/jsfiles/setupReplicaSet.js" htaox/mongodb-worker:3.0.2
    docker run --dns $NAMESERVER_IP -P -i -t -e SERVER1 ${hostmap["mongos${i}r1"]} -e SERVER2 ${hostmap["mongos${i}r2"]} -e OPTIONS=" ${hostmap["mongos${i}r1"]}:27017/local /root/jsfiles/setupReplicaSet.js" htaox/mongodb-worker:3.0.2

  done
}

function createConfigContainers() {
  #should have exactly 3
  # Create configserver
  for i in `seq 1 3`; do
    WORKER=$(docker run --dns $NAMESERVER_IP --name mongos-configserver${i} -P -i -d -v ${WORKER_VOLUME_DIR}-cfg:/data/db -e OPTIONS="d --configsvr --dbpath /data/db --notablescan --noprealloc --smallfiles --port 27017" htaox/mongodb-worker:3.0.2)
    sleep 3
    hostname=mongos-configserver${i}
    echo "Removing $hostname from $DNSFILE"
    sed -i "/$hostname/d" "$DNSFILE"
    WORKER_IP=$(docker logs $WORKER 2>&1 | egrep '^WORKER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
    echo "address=\"/$hostname/$WORKER_IP\"" >> $DNSFILE
    echo "$hostname IP: $WORKER_IP"
    hostmap[$hostname]=$WORKER_IP
  done
}

function createShardContainers() {

  # split the volume syntax by :, then use the array to build new volume map
  IFS=' ' read -ra VOLUME_MAP_ARR_PRE <<< "$VOLUME_MAP"
  IFS=':' read -ra VOLUME_MAP_ARR <<< "${VOLUME_MAP_ARR_PRE[1]}"

  for i in `seq 1 $NUM_WORKERS`; do

    echo "starting worker container"
    #hostname="${WORKER_HOSTNAME}${i}${DOMAINNAME}"
    # rename $VOLUME_MAP by adding worker number as suffix if it is not empty
    WORKER_VOLUME_MAP=$VOLUME_MAP
    if [ "$VOLUME_MAP" ]; then
      WORKER_VOLUME_DIR="${VOLUME_MAP_ARR[0]}-${i}"
      echo "Creating directory ${WORKER_VOLUME_DIR}"
      #mkdir -p "${WORKER_VOLUME_DIR}"
      mkdir -p "${WORKER_VOLUME_DIR}-1"
      mkdir -p "${WORKER_VOLUME_DIR}-2"
      mkdir -p "${WORKER_VOLUME_DIR}-cfg"
      
    fi
    
    # Create mongd servers
    WORKER=$(docker run --dns $NAMESERVER_IP --name mongos${i}r1 -P -i -d -v ${WORKER_VOLUME_DIR}-1:/data/db -e OPTIONS="d --replSet set${i} --dbpath /data/db --notablescan --noprealloc --smallfiles" htaox/mongodb-worker:3.0.2)
    sleep 10
    hostname=mongos${i}r1
    echo "Removing $hostname from $DNSFILE"
    sed -i "/$hostname/d" "$DNSFILE"
    WORKER_IP=$(docker logs $WORKER 2>&1 | egrep '^WORKER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
    echo "address=\"/$hostname/$WORKER_IP\"" >> $DNSFILE
    echo "$hostname IP: $WORKER_IP"
    hostmap[$hostname]=$WORKER_IP

    WORKER=$(docker run --dns $NAMESERVER_IP --name mongos${i}r2 -P -i -d -v ${WORKER_VOLUME_DIR}-2:/data/db -e OPTIONS="d --replSet set${i} --dbpath /data/db --notablescan --noprealloc --smallfiles" htaox/mongodb-worker:3.0.2)
    sleep 10
    hostname=mongos${i}r2
    echo "Removing $hostname from $DNSFILE"
    sed -i "/$hostname/d" "$DNSFILE"
    WORKER_IP=$(docker logs $WORKER 2>&1 | egrep '^WORKER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
    echo "address=\"/$hostname/$WORKER_IP\"" >> $DNSFILE
    echo "$hostname IP: $WORKER_IP"
    hostmap[$hostname]=$WORKER_IP
   
  done
}

function createQueryRouterContainers() {
  # Setup and configure mongo router
  CONFIG_DBS=""
  for i in `seq 1 3`; do
    CONFIG_DBS="${CONFIG_DBS}${hostmap[mongos-configserver${i}]}:27017"
    if [ $i -lt $(($NUM_WORKERS-1)) ]; then
      CONFIG_DBS="${CONFIG_DBS},"
    fi
  done

  echo "Config dbs --> ${CONFIG_DBS}"

  # Actually running mongos --configdb ...
  WORKER=$(docker run --dns $NAMESERVER_IP --name mongos1 -P -i -d -e OPTIONS="s --configdb ${CONFIG_DBS} --port 27017" htaox/mongodb-worker:3.0.2)
  sleep 10 # Wait for mongo to start
  hostname=mongos1
  echo "Removing $hostname from $DNSFILE"
  sed -i "/$hostname/d" "$DNSFILE"
  WORKER_IP=$(docker logs $WORKER 2>&1 | egrep '^WORKER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
  echo "address=\"/$hostname/$WORKER_IP\"" >> $DNSFILE
  echo "$hostname IP: $WORKER_IP"
  hostmap[$hostname]=$WORKER_IP

  #docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" $NAMESERVER_IP:$(docker port mongos1 27017|cut -d ":" -f2) /root/jsfiles/addShard.js" htaox/mongodb-worker:3.0.2
  for i in `seq 1 $NUM_WORKERS`; do
    echo "Adding shard for WORKER:${i}"
    docker run --dns $NAMESERVER_IP -P -i -t -e WORKERNUM=${i} -e OPTIONS=" mongos1:27017 /root/jsfiles/addShard.js" htaox/mongodb-worker:3.0.2
    sleep 5 # Wait for sharding to be enabled
  done
  
  #docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" $NAMESERVER_IP:$(docker port mongos1 27017|cut -d ":" -f2) /root/jsfiles/addDBs.js" htaox/mongodb-worker:3.0.2
  echo "Test insert"
  docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" mongos1:27017 /root/jsfiles/addDBs.js" htaox/mongodb-worker:3.0.2
  sleep 5 # Wait for db to be created
  #docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" $NAMESERVER_IP:$(docker port mongos1 27017|cut -d ":" -f2)/admin /root/jsfiles/enabelSharding.js" htaox/mongodb-worker:3.0.2
  echo "Enable shard"
  docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" mongos1:27017/admin /root/jsfiles/enableSharding.js" htaox/mongodb-worker:3.0.2
  sleep 5 # Wait sharding to be enabled
  #docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" $NAMESERVER_IP:$(docker port mongos1 27017|cut -d ":" -f2) /root/jsfiles/addIndexes.js" htaox/mongodb-worker:3.0.2
  echo "Test indexes"
  docker run --dns $NAMESERVER_IP -P -i -t -e OPTIONS=" mongos1:27017 /root/jsfiles/addIndexes.js" htaox/mongodb-worker:3.0.2
}

function start_workers() {
  
  echo "-------------------------------------"
  echo "Creating Shard Containers"
  echo "-------------------------------------"
  createShardContainers  
  
  echo "-------------------------------------"
  echo "Creating Config Containers"
  echo "-------------------------------------"
  createConfigContainers

  echo "-------------------------------------"
  echo "Initiating Replica Sets"
  echo "-------------------------------------"
  sleep 3
  initiateReplicatSets
  
  echo "-------------------------------------"
  echo "Configuring Query Router Containers"
  echo "-------------------------------------"
  createQueryRouterContainers

  echo "#####################################"
  echo "MongoDB Cluster is now ready to use"
  echo "Connect to cluster by:"
  echo "$ mongo --port $(docker port mongos1 27017|cut -d ":" -f2)"
}

