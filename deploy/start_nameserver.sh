#!/bin/bash

NAMESERVER=-1
NAMESERVER_IP=
DOMAINNAME=
#".mycluster.com"
BASEDIR=$(cd $(dirname $0); pwd)

# starts the dnsmasq nameserver
function start_nameserver() {
    DNSDIR="/opt/docker-dns/dnsdir_$RANDOM"
    #DNSDIR="${BASEDIR}"
    DNSFILE="${DNSDIR}/0hosts"
    mkdir -p $DNSDIR >> $LOG 2>&1

    rm -rf /opt/docker-dns/DNSMASQ >> $LOG 2>&1
    touch /opt/docker-dns/DNSMASQ >> $LOG 2>&1
    echo $DNSFILE | tee --append /opt/docker-dns/DNSMASQ
    chmod 777 /opt/docker-dns/DNSMASQ >> $LOG 2>&1

    echo "starting nameserver container"
    if [ "$DEBUG" -gt 0 ]; then
        echo sudo docker run -d --restart always -h nameserver${DOMAINNAME} -v $DNSDIR:/etc/dnsmasq.d $1
    fi
    NAMESERVER=$(sudo docker run -d --restart always -h nameserver${DOMAINNAME} -v $DNSDIR:/etc/dnsmasq.d $1)

    if [ "$NAMESERVER" = "" ] && [ "$DEBUG" = "0" ]; then
        echo "error: could not start nameserver container from image $1"
        exit 1
    fi

    echo "started nameserver container:  $NAMESERVER"
    echo "DNS host->IP file mapped:      $DNSFILE"
    sleep 2

    chmod -R 777 $DNSDIR >> $LOG 2>&1

    NAMESERVER_IP=$(sudo docker logs $NAMESERVER 2>&1 | egrep '^NAMESERVER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
    echo "NAMESERVER_IP:                 $NAMESERVER_IP"
    echo "address=\"/nameserver/$NAMESERVER_IP\"" > $DNSFILE

}

# contact nameserver container and resolve IP address (used for checking whether nameserver has registered
# presence of new container). note: only returns exit code
function check_hostname() {
    local __resultvar=$1
    local val_hostname=$2
    local val_expected_ip=$3
    if [ "$NAMESERVER_IP" = "" ]; then NAMESERVER_IP="127.0.0.1" ; fi
    if which dig >/dev/null; then
        DNSCMD="dig $val_hostname @${NAMESERVER_IP} | grep ANSWER -A1 | grep $val_expected_ip > /dev/null"
    else
        DNSCMD="nslookup $val_hostname $NAMESERVER_IP | grep Address | tail -n 1 | grep $val_expected_ip > /dev/null"
    fi
    echo "DNSCMD: $DNSCMD"
    eval $DNSCMD >> $LOG 2>&1
    eval $__resultvar=$?
}

# contact nameserver container and resolve IP address
function resolve_hostname() {
    local __resultvar=$1
    local val_hostname=$2
    if which dig >/dev/null; then
        DNSCMD="dig $val_hostname @${NAMESERVER_IP} | grep ANSWER -A1 | tail -n 1 | awk '{print \$5}'"
    else
        DNSCMD="nslookup $val_hostname $NAMESERVER_IP | grep Address | tail -n 1 | awk -F":" '{print \$2}' | awk '{print \$1}'"
    fi
    #echo "DNSCMD: $DNSCMD"
    tmpval=$(eval "$DNSCMD")
    eval $__resultvar="$tmpval"
}

function wait_for_nameserver {
    attempt=$((0))
    echo -n "waiting for nameserver to come up "
    # Note: the original scripts assumed the nameserver resolves its own
    # hostname to 127.0.0.1
    # With newer versions of Docker that is not necessarily the case anymore.
    # Thanks to bmustafa (24601 on GitHub) for reporting and proposing a fix!
    check_hostname result nameserver "$NAMESERVER_IP"
    until [ "$result" -eq 0 ]; do
        echo -n "."
        attempt=$((attempt+1))
        sleep 1
        if [ "$attempt" -gt 1 ]; then break ; fi
        check_hostname result nameserver "$NAMESERVER_IP"        
    done
    echo ""
}

function check_nameserver() {
    nameservers=$(sudo docker ps | grep dnsmasq_files | awk '{print $1}' | tr '\n' ' ')
    containers=($nameservers)
    NUM_NAMESERVERS=$(echo ${#containers[@]})
    echo "There are $NUM_NAMESERVERS nameservers"
}

function check_start_nameserver() {

    check_nameserver

    if [ "$NUM_NAMESERVERS" -eq 0 ]; then
        start_nameserver $1
        # start_nameserver $NAMESERVER_IMAGE
        wait_for_nameserver
    else
        HOSTFILE=$(cat /opt/docker-dns/DNSMASQ)
        DNSFILE=$HOSTFILE
        NAMESERVER_IP=$(cat $HOSTFILE | grep nameserver | grep -oE "[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}")
        echo "NAMESERVER_IP: $NAMESERVER_IP"        
    fi    
}
