#!/bin/bash
#########################################################################################
## Hadoop single node cluster
#########################################################################################
# Installs Pseudo-Distributed Operation mode on a single node
# built via https://github.com/mgis-architects/terraform/tree/master/azure/hadoop
# This script only supports Azure currently, mainly due to the disk persistence method
#
# USAGE:
#
#    sudo hadoopOneNode-build.sh ~/hadoopOneNode-build.ini
#
# USEFUL LINKS: 
# 
# docs:    
# install: https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-common/SingleCluster.html
# useful:
#           NameNode            http://localhost:50070/    web interface for the NameNode
#           ResourceManager     http://localhost:8088/
#
#########################################################################################

g_prog=hadoopOneNode-build
RETVAL=0

######################################################
## defined script variables
######################################################
STAGE_DIR=/tmp/$g_prog/stage
LOG_DIR=/var/log/$g_prog
LOG_FILE=$LOG_DIR/${prog}.log.$(date +%Y%m%d_%H%M%S_%N)
INI_FILE=$LOG_DIR/${g_prog}.ini

THISDIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SCR=$(basename "${BASH_SOURCE[0]}")
THIS_SCRIPT=$THISDIR/$SCR

######################################################
## log()
##
##   parameter 1 - text to log
##
##   1. write parameter #1 to current logfile
##
######################################################
function log ()
{
    if [[ -e $LOG_DIR ]]; then
        echo "$(date +%Y/%m/%d_%H:%M:%S.%N) $1" >> $LOG_FILE
    fi
}

######################################################
## fatalError()
##
##   parameter 1 - text to log
##
##   1.  log a fatal error and exit
##
######################################################
function fatalError ()
{
    MSG=$1
    log "FATAL: $MSG"
    echo "ERROR: $MSG"
    exit -1
}

function installRPMs()
{
    INSTALL_RPM_LOG=$LOG_DIR/yum.${g_prog}_install.log.$$

    STR=""
    STR="$STR java-1.7.0-openjdk.x86_64 cifs-utils"
    
    yum makecache fast
    
    echo "installRPMs(): to see progress tail $INSTALL_RPM_LOG"
    if ! yum -y install $STR > $INSTALL_RPM_LOG
    then
        fatalError "installRPMs(): failed; see $INSTALL_RPM_LOG"
    fi
}

function fixSwap()
{
    cat /etc/waagent.conf | while read LINE
    do
        if [ "$LINE" == "ResourceDisk.EnableSwap=n" ]; then
                LINE="ResourceDisk.EnableSwap=y"
        fi

        if [ "$LINE" == "ResourceDisk.SwapSizeMB=2048" ]; then
                LINE="ResourceDisk.SwapSizeMB=14000"
        fi
        echo $LINE
    done > /tmp/waagent.conf
    /bin/cp /tmp/waagent.conf /etc/waagent.conf
    systemctl restart waagent.service
}

createFilesystem()
{
    # createFilesystem /u01 $l_disk $diskSectors  
    # size is diskSectors-128 (offset)

    local p_filesystem=$1
    local p_disk=$2
    local p_sizeInSectors=$3
    local l_sectors
    local l_layoutFile=$LOG_DIR/sfdisk.${g_prog}_install.log.$$
    
    if [ -z $p_filesystem ] || [ -z $p_disk ] || [ -z $p_sizeInSectors ]; then
        fatalError "createFilesystem(): Expected usage mount,device,numsectors, got $p_filesystem,$p_disk,$p_sizeInSectors"
    fi
    
    let l_sectors=$p_sizeInSectors-128
    
    cat > $l_layoutFile << EOFsdcLayout
# partition table of /dev/sdc
unit: sectors

/dev/sdc1 : start=     128, size=  ${l_sectors}, Id= 83
/dev/sdc2 : start=        0, size=        0, Id= 0
/dev/sdc3 : start=        0, size=        0, Id= 0
/dev/sdc4 : start=        0, size=        0, Id= 0
EOFsdcLayout

    set -x # debug has been useful here

    if ! sfdisk $p_disk < $l_layoutFile; then fatalError "createFilesystem(): $p_disk does not exist"; fi
    
    sleep 4 # add a delay - experiencing occasional "cannot stat" for mkfs
    
    log "createFilesystem(): Dump partition table for $p_disk"
    fdisk -l 
    
    if ! mkfs.ext4 ${p_disk}1; then fatalError "createFilesystem(): mkfs.ext4 ${p_disk}1"; fi
    
    if ! mkdir -p $p_filesystem; then fatalError "createFilesystem(): mkdir $p_filesystem failed"; fi
    
    if ! chmod 755 $p_filesystem; then fatalError "createFilesystem(): chmod $p_filesystem failed"; fi
    
    # if ! chown oracle:oinstall $p_filesystem; then fatalError "createFilesystem(): chown $p_filesystem failed"; fi
    
    if ! mount ${p_disk}1 $p_filesystem; then fatalError "createFilesystem(): mount $p_disk $p_filesytem failed"; fi

    log "createFilesystem(): Dump blkid"
    blkid
    
    if ! blkid | egrep ${p_disk}1 | awk '{printf "%s\t'${p_filesystem}' \t ext4 \t defaults \t 1 \t2\n", $2}' >> /etc/fstab; then fatalError "createFilesystem(): fstab update failed"; fi

    log "createFilesystem() fstab success: $(grep $p_disk /etc/fstab)"

    set +x    
}

function allocateStorage() 
{
    local l_disk
    local l_size
    local l_sectors
    local l_hasPartition

    for l_disk in /dev/sd? 
    do
         l_hasPartition=$(( $(fdisk -l $l_disk | wc -l) != 6 ? 1 : 0 ))
        # only use if it doesnt already have a blkid or udev UUID
        if [ $l_hasPartition -eq 0 ]; then
            let l_size=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $5}'`/1024/1024/1024
            let l_sectors=`fdisk -l $l_disk | grep 'Disk.*sectors' | awk '{print $7}'`
            
            if [ $u01_Disk_Size_In_GB -eq $l_size ]; then
                log "allocateStorage(): Creating /u01 on $l_disk"
                createFilesystem /u01 $l_disk $l_sectors
            fi
        fi
    done   
}

function mountMedia() {

    if [ -f /mnt/software/ogg4bd12201/p24816159_122014_Linux-x86-64.zip ]; then
    
        log "mountMedia(): Filesystem already mounted"
        
    else
    
        umount /mnt/software
    
        mkdir -p /mnt/software
        
        eval `grep mediaStorageAccountKey $INI_FILE`
        eval `grep mediaStorageAccount $INI_FILE`
        eval `grep mediaStorageAccountURL $INI_FILE`

        l_str=""
        if [ -z $mediaStorageAccountKey ]; then
            l_str+="mediaStorageAccountKey not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccount ]; then
            l_str+="mediaStorageAccount not found in $INI_FILE; "
        fi
        if [ -z $mediaStorageAccountURL ]; then
            l_str+="mediaStorageAccountURL not found in $INI_FILE; "
        fi
        if ! [ -z $l_str ]; then
            fatalError "mountMedia(): $l_str"
        fi

        cat > /etc/cifspw << EOF1
username=${mediaStorageAccount}
password=${mediaStorageAccountKey}
EOF1

        cat >> /etc/fstab << EOF2
//${mediaStorageAccountURL}     /mnt/software   cifs    credentials=/etc/cifspw,vers=3.0,gid=54321      0       0
EOF2

        mount -a
        
    fi
    
}


function addGroups()
{
    local l_group_list=$LOG_DIR/groups.${g_prog}.lst.$$
    local l_found
    local l_user
    local l_x
    local l_gid
    local l_newgid
    local l_newgname

    cat > $l_group_list << EOFaddGroups
55555 hadoop
EOFaddGroups

    while read l_newgid l_newgname
    do    
    
        local l_found=0
        grep $l_newgid /etc/group | while IFS=: read l_gname l_x l_gid
        do
            if [ $l_gname != $l_newgname ]; then
                fatalError "addGroups(): gid $l_newgid exists with a different group name $l_gname"
            fi
        done
        
        log "addGroups(): /usr/sbin/groupadd -g $l_newgid $l_newgname"
        if ! /usr/sbin/groupadd -g $l_newgid $l_newgname; then 
            log "addGroups() failed on $l_newgid $l_newgname"
        fi
    
    done < $l_group_list   
}

function addUsers()
{

    if ! id -a oracle 2> /dev/null; then
        /usr/sbin/useradd -u 55555 -g hadoop hadoop -p c6kTxMi2LR1l2
    else
        fatalError "addUsers(): user 55555/hadoop already exists"
    fi
}


function installHadoopOneNode() 
{
    local l_script=$LOG_DIR/$g_prog.install.$$.sh
    local l_log=$LOG_DIR/$g_prog.install.$$.log
    
    chmod 755 /u01
    mkdir -p /u01/app/hadoop
    chown -R hadoop:hadoop /u01/app
    mkdir /var/log/hadoop
    chown hadoop:hadoop /var/log/hadoop

    cat > ${l_script} << EOFinstall
    
    mkdir ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t dsa -P '' -f ~/.ssh/id_dsa
    cat ~/.ssh/id_dsa.pub >> ~/.ssh/authorized_keys
    chmod 0600 ~/.ssh/authorized_keys
    
    cd /u01/app/hadoop
    export JAVA_HOME=/etc/alternatives/jre_1.8.0
    tar xzf /mnt/software/hadoop/hadoop-2.7.3.tar.gz
    
    cp etc/hadoop/core-site.xml etc/hadoop/core-site.xml.orig
    cp etc/hadoop/hdfs-site.xml etc/hadoop/hdfs-site.xml.orig
    
    cat > etc/hadoop/core-site.xml << EOFcs
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://localhost:9000</value>
    </property>
</configuration>
EOFcs

    cat > etc/hadoop/hdfs-site.xml << EOFhs
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>1</value>
    </property>
</configuration>
EOFhs

    bin/hdfs namenode -format
    nohup sbin/start-dfs.sh > /var/log/hadoop/dfs.log 2>&1 &
    
    bin/hdfs dfs -mkdir /user
    bin/hdfs dfs -mkdir /user/hadoop
    bin/hdfs dfs -put etc/hadoop input
    bin/hadoop jar share/hadoop/mapreduce/hadoop-mapreduce-examples-2.7.3.jar grep input output 'dfs[a-z.]+'
    bin/hdfs dfs -cat output/*
    
    cp etc/hadoop/mapred-site.xml etc/hadoop/mapred-site.xml.orig
    cp etc/hadoop/yarn-site.xml etc/hadoop/yarn-site.xml.orig
    
    cat > etc/hadoop/mapred-site.xml << EOFyarn1
<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
    </property>
</configuration>
EOFyarn1

    cat > etc/hadoop/yarn-site.xml << EOFyarn2
<configuration>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
</configuration>
EOFyarn2

    nohup sbin/start-yarn.sh > /var/log/hadoop/yarn.log 2>&1 &
    
EOFinstall

    su - hadoop -c "bash -x ${l_script} 2>&1 | tee ${l_log}"
    

}

function openFirewall() {
    firewall-cmd --zone=public --add-port=8088,9000,50070,/tcp --permanent
    firewall-cmd --reload
    firewall-cmd --zone=public --list-all
}


function run()
{
    eval `grep platformEnvironment $INI_FILE`
    if [ -z $platformEnvironment ]; then    
        fatalError "$g_prog.run(): Unknown environment, check platformEnvironment setting in iniFile"
    elif [ $platformEnvironment != "AZURE" ]; then    
        fatalError "$g_prog.run(): platformEnvironment=AZURE is the only valid setting currently"
    fi

    eval `grep u01_Disk_Size_In_GB $INI_FILE`

    l_str=""
    if [ -z $u01_Disk_Size_In_GB ]; then
        l_str+="asmStorage(): u01_Disk_Size_In_GB not found in $INI_FILE; "
    fi
    if ! [ -z $l_str ]; then
        fatalError "$g_prog(): $l_str"
    fi
    
    # function calls
    fixSwap
    installRPMs 
    allocateStorage
    mountMedia
    openFirewall
    addGroups
    addUsers
    installHadoop
}


######################################################
## Main Entry Point
######################################################

log "$g_prog starting"
log "STAGE_DIR=$STAGE_DIR"
log "LOG_DIR=$LOG_DIR"
log "INI_FILE=$INI_FILE"
log "LOG_FILE=$LOG_FILE"
echo "$g_prog starting, LOG_FILE=$LOG_FILE"

if [[ $EUID -ne 0 ]]; then
    fatalError "$THIS_SCRIPT must be run as root"
    exit 1
fi

INI_FILE_PATH=$1

if [[ -z $INI_FILE_PATH ]]; then
    fatalError "${g_prog} called with null parameter, should be the path to the driving ini_file"
fi

if [[ ! -f $INI_FILE_PATH ]]; then
    fatalError "${g_prog} ini_file cannot be found"
fi

if ! mkdir -p $LOG_DIR; then
    fatalError "${g_prog} cant make $LOG_DIR"
fi

chmod 777 $LOG_DIR

cp $INI_FILE_PATH $INI_FILE

run

log "$g_prog ended cleanly"
exit $RETVAL

