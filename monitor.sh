#!/usr/bin/env bash
set -eu
set -o pipefail

# check log path
CHECK_LOCK_PATH="/var/run/qc_paas_monitor.lock"

# hostname
INSTANCE_ID=$(hostname)

# cluster type
CLUSTER_TYPE=

# robot id
ROBOT_ID=

# robot url prefix
robot_prefix="https://qyapi.weixin.qq.com/cgi-bin/webhook/send?key="

# message definition
# common
MSG_C00="wrong input number, do nothing"
# mongo
MSG_MONGO_01="process mongod is not running"
MSG_MONGO_02="exec mongo shell failed"
MSG_MONGO_03="not all nodes are recognized by cluster"
MSG_MONGO_04="some nodes are not health"

main() {
    # single-instance mechanism
    if [ -e $CHECK_LOCK_PATH ] && kill -0 $(cat $CHECK_LOCK_PATH); then
        log "health check is already running, skipping"
        return 0
    fi

    trap "rm -f $CHECK_LOCK_PATH; exit" INT TERM EXIT
    echo $$ > $CHECK_LOCK_PATH

    if [ $# -lt 2 ]; then
        echo "wrong input number, do nothing"
        return 0
    fi

    # get cluster type and robot id
    CLUSTER_TYPE=$1
    ROBOT_ID=$2
    shift 2
    # call proper monitor
    msg_id=""
    if ! msg_id=$(eval "${CLUSTER_TYPE}_monitor $@"); then
        echo "$CLUSTER_TYPE monitor is not registered"
        return 0
    fi

    if [ -z "$msg_id" ]; then
        echo "all is fine, just return"
        return
    fi
    # send message
    echo "$CLUSTER_TYPE message with id $msg_id will be send"
    sendMsg $(echo $CLUSTER_TYPE | tr '[:lower:]' '[:upper:]') $msg_id $ROBOT_ID
}

# $1 - cluster type
# $2 - msg id
getRealMsg() {
    res=""
    if [ ${2:0:1} = "C" ]; then
        eval "res=\${MSG_$2:-unknown message id}"
    else
        eval "res=\${MSG_$1_$2:-unknown message id}"
    fi
    echo $res
}

# $1 - cluster type
# $2 - msg id
# $3 - robot id
sendMsg() {
    show_msg=$(getRealMsg $1 $2)
    content=$(cat<<MYCONTENT
Instance: $INSTANCE_ID, ClusterType: $(echo $1 | tr '[:upper:]' '[:lower:]')
$show_msg
MYCONTENT
    )
    json_str=$(echo "$content" | sed ':a;N;$!ba;s/\n/\\n/g;s/\"/\\\"/g')

    # post data
    postData=$(cat<<MYPOSTDATA
{
    "msgtype": "text",
    "text": {
        "content": "$json_str"
    }
}
MYPOSTDATA
    )

    # send message
    robot_url=$robot_prefix$3
    echo "$postData"
    echo $robot_url
    # curl -s -XPOST -H 'Content-Type: application/json' $robot_url -d "$postData1" >/dev/null 2>&1 | :
}

# $1 - node count
mongo_monitor() {
    if [ $# -lt 1 ]; then
        echo "C00"
        return 0
    fi
    if ! pgrep mongod >/dev/null 2>&1; then
        echo "01"
        return 0
    fi
    mongo_status_raw=""
    if ! mongo_status_raw=$(mongo -u qc_master -p $(cat /data/pitrix.pwd) --authenticationDatabase admin --eval 'printjson(rs.status().members)' --quiet); then
        echo "02"
        return 0
    fi
    all_health=$(echo "$mongo_status_raw" | sed -n '/"health" : [01]/p')
    all_cnt=$(echo "$all_health" | wc -l)
    if ! [ "$1" = "$all_cnt" ]; then
        echo "03"
        return 0
    fi
    if echo "$all_health" | grep "0" >/dev/null 2>&1; then
        echo "04"
        return 0
    fi
}

main $@