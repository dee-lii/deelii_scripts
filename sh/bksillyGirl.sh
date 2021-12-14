#!/bin/bash
cd / #回到根目录才能实行绝对路径的备份

path="/root/qlbk" #备份到对应目录下

way="/root/QL/db" #需要备份的路径

con="qlbk" #变量命名

tar -zvcPf /root/qlbk/bk.`date +%F`.tar.gz /root/QL/db >/dev/null 2>>/root/qlbk/bklog.log

#对文件进行性备份，备份的目录内容是/etc

num=`ls -l $path | grep -E "\\..*\.tar.gz$" | wc -l` #统计文件的数量

#判断是否为四个文件
if [ $num -gt 4 ] 

then

#删除前一天的备份文件
rm -rf $path/`ls -l $path | grep "\\..*\.tar.gz$" | head -n 1 | awk '{print $NF}' | xargs`

#输出备份成功提示
echo -e "\033[32m The backup successful \033[0m" 

fi