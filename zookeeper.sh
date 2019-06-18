#!/bin/bash
sudo parted /dev/sdc mklabel msdos
sudo parted /dev/sdc mkpart primary ext4 0% 100%
sudo mkfs -t ext4 /dev/sdc1
uuid=$(sudo blkid | sed -n 's/.*sdc.: *UUID=\"\([^"]*\).*/\1/p')
echo "UUID=$uuid	/data	ext4	defaults,nofail	0	2" | sudo tee -a /etc/fstab
sudo mkdir /data
sudo mount /dev/sdc1 /data
sudo mkdir -p /data/zookeeper
sudo chmod a+w /data/zookeeper


sudo parted /dev/sdd mklabel msdos
sudo parted /dev/sdd mkpart primary ext4 0% 100%
sudo mkfs -t ext4 /dev/sdd1
uuid=$(sudo blkid | sed -n 's/.*sdd.: *UUID=\"\([^"]*\).*/\1/p')
echo "UUID=$uuid	/logs	ext4	defaults,nofail	0	2" | sudo tee -a /etc/fstab
sudo mkdir /logs
sudo mount /dev/sdd1 /logs
sudo mkdir -p /logs/zookeeper
sudo chmod a+w /logs/zookeeper

wget "https://download.java.net/java/GA/jdk10/10.0.2/19aef61b38124481863b1413dce1855f/13/openjdk-10.0.2_linux-x64_bin.tar.gz"
tar -xvf openjdk-10*
mkdir /usr/lib/jvm
mv ./jdk-10* /usr/lib/jvm/jdk10.0.2
update-alternatives --install "/usr/bin/java" "java" "/usr/lib/jvm/jdk10.0.2/bin/java" 1
update-alternatives --install "/usr/bin/javac" "javac" "/usr/lib/jvm/jdk10.0.2/bin/javac" 1
chmod a+x /usr/bin/java
chmod a+x /usr/bin/javac

cd /usr/local

zookeeperVersion="3.4.14"

wget "http://www-us.apache.org/dist/zookeeper/zookeeper-3.4.14/zookeeper-$zookeeperVersion.tar.gz"
tar -xvf "zookeeper-$zookeeperVersion.tar.gz"

touch zookeeper-$zookeeperVersion/conf/zoo.cfg

echo "tickTime=2000" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "dataDir=/data/zookeeper" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "dataLogDir=/logs/zookeeper" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "autopurge.snapRetainCount=3" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "autopurge.purgeInterval=24" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "clientPort=2181" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "initLimit=5" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
echo "syncLimit=2" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
 
i=1
while [ $i -le $2 ]
do
    echo "server.$i=10.1.1.$(($i+3)):2888:3888" >> zookeeper-$zookeeperVersion/conf/zoo.cfg
    i=$(($i+1))
done

echo $(($1+1)) >> /data/zookeeper/myid

# Default zookeeper logs to console which the zkServer.sh script
# redirects to the file zookeeper.out that file is generated
# where it is ran. That is typically the os drive
# this can cause diskspace issues for small os drives
export ZOO_LOG_DIR=/logs/zookeeper
export ZOO_LOG4J_PROP='INFO,ROLLINGFILE'

export SERVER_JVMFLAGS=-Xmx12288m
zookeeper-$zookeeperVersion/bin/zkServer.sh start
