#!/bin/bash
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

# redis-cli path
REDIS_CLI_PATH_LIST="/usr/bin/redis-cli,/opt/redis-3.0.5/bin/redis-cli"

# message definition
# common
MSG_C00="wrong input number, do nothing"
MSG_C01="can't locate the path of redis-cli"
MSG_C99="this is a test"
# mongo
MSG_MONGO_01="process mongod is not running"
MSG_MONGO_02="exec mongo shell failed"
MSG_MONGO_03="not all nodes are recognized by cluster"
MSG_MONGO_04="some nodes are not health"
# postgres
MSG_PG_01="process postgres is not running"
MSG_PG_02="can't fetch pg's running tasks"
MSG_PG_03="can't detect sender or receiver task"
# redisreplica
MSG_REDISREPLICA_01="process redis-server is not running"
MSG_REDISREPLICA_02="exec redis-cli failed"
MSG_REDISREPLICA_03="can't fetch redis role"
MSG_REDISREPLICA_04="not all slave nodes are found by master"
# rediscluster
MSG_REDISCLUSTER_01="process redis-server is not running"
MSG_REDISCLUSTER_02="exec redis-cli failed"
MSG_REDISCLUSTER_03="not all nodes are recognized by cluster"
MSG_REDISCLUSTER_04="can't fetch redis role"
MSG_REDISCLUSTER_05="not all slave nodes are found by master"
# mysql
MSG_MYSQL_01="process mysqld or proxy is not running"
MSG_MYSQL_02="exec mysql command faild"
MSG_MYSQL_03="Slave_IO_Running or Slave_SQL_Running is 'No'"
MSG_MYSQL_04="Seconds_Behind_Master is greater than 10"

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

curl_path="/data/curl"
# $1 - cluster type
# $2 - msg id
# $3 - robot id
sendMsg() {
    show_msg=$(getRealMsg $1 $2)
    content=$(cat<<MYCONTENT
Instance: $INSTANCE_ID
ClusterType: $(echo $1 | tr '[:upper:]' '[:lower:]')
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
    $curl_path -s -XPOST -H 'Content-Type: application/json' $robot_url -d "$postData" | :
}

# just for test
test_monitor() {
    echo "C99"
}

# mongo exec path
mongo_path=/usr/bin/mongo

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
    if ! mongo_status_raw=$($mongo_path -u qc_master -p $(cat /data/pitrix.pwd) --authenticationDatabase admin --eval 'printjson(rs.status().members)' --quiet); then
        echo "02"
        return 0
    fi
    all_health=$(echo "$mongo_status_raw" | sed -n '/"health" : [01]/p')
    all_cnt=$(echo "$all_health" | wc -l)
    if [ "$1" -ne "$all_cnt" ]; then
        echo "03"
        return 0
    fi
    if echo "$all_health" | grep "0" >/dev/null 2>&1; then
        echo "04"
        return 0
    fi
}

pg_monitor() {
    if ! pgrep postgres >/dev/null 2>&1; then
        echo "01"
        return 0
    fi
    pg_status_raw=""
    if ! pg_status_raw=$(ps -ef | grep postgres); then
        echo "02"
        return 0
    fi
    pg_wal_info=$(echo "$pg_status_raw" | sed -n '/wal sender/p; /wal receiver/p')
    if [ -z "$pg_wal_info" ]; then
        echo "03"
        return 0
    fi
}

# get redis-cli path
# no acl settings for redis version less then 6.0
# but they use 'requirepass' to setup password
# $1 - password (optional)
get_rediscli() {
    res=""
    real_path=""
    for line in $(echo $REDIS_CLI_PATH_LIST | tr ',' '\n'); do
        if [ -f "$line" ]; then
            real_path=$line
            break
        fi
    done
    if [ -z "$real_path" ]; then
        return
    fi
    # test if redis-cli support --no-auth-warning
    if $real_path --no-auth-warning info >/dev/null 2>&1; then
        res="$real_path --no-auth-warning"
    else
        res="$real_path"
    fi
    if [ $# -gt 0 ]; then
        res="$res -a $1"
    fi
    echo "$res"
}

# $1 - redis node count
# $2 - password (optional)
redisreplica_monitor() {
    if [ $# -lt 1 ]; then
        echo "C00"
        return 0
    fi
    if ! pgrep redis-server >/dev/null 2>&1; then
        echo "01"
        return 0
    fi
    redis_node_cnt=$1
    shift
    redis_cli=$(get_rediscli $@)
    if [ -z "$redis_cli" ]; then
        echo "C01"
        return 0
    fi
    redis_replica_raw=""
    if ! redis_replica_raw=$($redis_cli info replication); then
        echo "02"
        return 0
    fi
    redis_role=$(echo "$redis_replica_raw" | sed -n '/^role/p' | sed 's/role://' | tr -d [:space:])
    if [ -z "$redis_role" ]; then
        echo "03"
        return 0
    fi
    if [ "$redis_role" = "slave" ]; then
        # do nothing when the node's role is slave
        return 0
    fi
    redis_role_info=""
    if ! redis_role_info=$($redis_cli role); then
        echo "02"
        return 0
    fi
    want_line_cnt=$((2+(redis_node_cnt-1)*3))
    real_line_cnt=$(echo "$redis_role_info" | wc -l)
    if [ "$want_line_cnt" -ne "$real_line_cnt" ]; then
        echo "04"
        return 0
    fi
}

# $1 - redis shard count
# $2 - redis replica count
# $3 - password (optional)
rediscluster_monitor() {
    if [ $# -lt 2 ]; then
        echo "C00"
        return 0
    fi
    if ! pgrep redis-server >/dev/null 2>&1; then
        echo "01"
        return 0
    fi
    redis_shard_cnt=$1
    redis_replica_cnt=$2
    shift 2
    redis_cli=$(get_rediscli $@)
    if [ -z "$redis_cli" ]; then
        echo "C01"
        return 0
    fi
    redis_cluster_raw=""
    if ! redis_cluster_raw=$($redis_cli cluster nodes); then
        echo "02"
        return 0
    fi
    want_cluster_node_cnt=$((redis_shard_cnt*(redis_replica_cnt+1)))
    real_cluster_node_cnt=$(echo "$redis_cluster_raw" | wc -l)
    if [ "$want_cluster_node_cnt" -ne "$real_cluster_node_cnt" ]; then
        echo "03"
        return 0
    fi
    redis_replica_raw=""
    if ! redis_replica_raw=$($redis_cli info replication); then
        echo "02"
        return 0
    fi
    redis_role=$(echo "$redis_replica_raw" | sed -n '/^role/p' | sed 's/role://' | tr -d [:space:])
    if [ -z "$redis_role" ]; then
        echo "04"
        return 0
    fi
    if [ "$redis_role" = "slave" ]; then
        # do nothing when the node's role is slave
        return 0
    fi
    redis_role_info=""
    if ! redis_role_info=$($redis_cli role); then
        echo "02"
        return 0
    fi
    want_line_cnt=$((2+redis_replica_cnt*3))
    real_line_cnt=$(echo "$redis_role_info" | wc -l)
    if [ "$want_line_cnt" -ne "$real_line_cnt" ]; then
        echo "05"
        return 0
    fi
}

mysql_path="/usr/bin/mysql"

mysql_monitor() {
    if ! pgrep -x mysqld >/dev/null 2>&1 && ! pgrep proxy >/dev/null 2>&1; then
        echo "01"
        return 0
    fi
    if pgrep proxy >/dev/null 2>&1; then
        # proxy needn't further check
        return 0
    fi
    if ! MYSQL_PWD=$(cat /data/pitrix.pwd) $mysql_path -uqc_master -e 'show master status\G' >/dev/null 2>&1; then
        echo "02"
        return 0
    fi
    mysql_slave_raw=""
    if ! mysql_slave_raw=$(MYSQL_PWD=$(cat /data/pitrix.pwd) $mysql_path -uqc_master -e 'show slave status\G'); then
        echo "02"
        return 0
    fi
    if [ -z "$mysql_slave_raw" ]; then
        # master node needn't further check
        return 0
    fi
    slave_io_running=$(echo "$mysql_slave_raw" | sed -n '/Slave_IO_Running:/p' | sed 's/Slave_IO_Running://' | tr -d '[:space:]')
    slave_sql_running=$(echo "$mysql_slave_raw" | sed -n '/Slave_SQL_Running:/p' | sed 's/Slave_SQL_Running://' | tr -d '[:space:]')
    if ! [ "$slave_io_running" = "Yes" -a "$slave_sql_running" = "Yes" ]; then
        echo "03"
        return 0
    fi
    slave_delay=$(echo "$mysql_slave_raw" | sed -n '/Seconds_Behind_Master:/p' | sed 's/Seconds_Behind_Master://' | tr -d '[:space:]')
    if [ "$slave_delay" -gt 10 ]; then
        echo "04"
        return 0
    fi
}

main $@