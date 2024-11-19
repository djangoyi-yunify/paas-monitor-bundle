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
# mongo
MSG_MONGO_01="11111"
MSG_MONGO_02="22222"

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
# $3 - robot id
sendMsg() {
    show_msg=""
    eval "show_msg=\${MSG_$1_$2:-unknown message}"
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

mongo_monitor() {
    echo "01"
}

main $@