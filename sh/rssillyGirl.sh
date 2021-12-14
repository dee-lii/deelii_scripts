#!/bin/bash
#判断进程是否存在，如果不存在就启动它
PIDS=`ps -ef |grep sillyGirl |grep -v grep | awk '{print $2}'`
if [ "$PIDS" != "" ]; then
echo $(date +%F%n%T)  "runing!" >> /root/sillyGirl/rs.log
else
echo $(date +%F%n%T) "not runing!" >> /root/sillyGirl/rs.log
kill -9 $PIDS
cd /root/sillyGirl &&  ./sillyGirl -d
#运行进程
fi