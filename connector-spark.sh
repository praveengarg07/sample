#!/bin/sh

trap "Clean_up" 0 1 2 3 13 15 # EXIT HUP INT QUIT PIPE TERM

# redirect script output to system logger with file basename
exec 1> >(logger -s -t $(basename $0)) 2>&1

SHC_ROOT="/etc/hbase/shc"
HBASE_CRON_SCRIPT_PATH="$SHC_ROOT/hbase-shc-cron.sh"
SPARK_CRON_SCRIPT_PATH="$SHC_ROOT/spark-shc-cron.sh"
CRON_SCRIPT_NAME="shc-cron.sh"
CRON_LOG_PATH="/var/log/hbase/shc-cron.log"

Help()
{
   echo ""
   echo "Example Usage: $0 -s '*/5 * * * *' -h '*/30 * * * *'"
   echo -e "\t-s SPARK_CRON_TIME"
   echo -e "\t-h HBASE_CRON_TIME"
   echo -e "\tDefault cron time for Spark = */1 * * * * (runs Spark scale check every 1 min), HBase = 0 (no automatic HBase scale check)."
   echo -e "\tIf your HBase cluster does not scale often, you may enter '-h '<your desired cron schedule>'', this will set up automatic checks for HBase scale up. \
     If you do not set up automatic checks and later decide to scale up your HBase cluster, run this script again on Spark script action portal to trigger file updates."
   exit 1 # Exit script after printing help
}

Clean_up()
{
    exit_status=$?
    sudo rm -f /tmp/shc-tmpcron
    echo "Connector Spark: Clean up temporary files. Exitting with code $exit_status."
    exit "$exit_status"
}


Build_HBase_Cron_Script()
{
    echo "Connector Spark: Adding HBase cron helper script to $node."

    sudo rm -f $HBASE_CRON_SCRIPT_PATH
    sudo tee $HBASE_CRON_SCRIPT_PATH &>/dev/null <<'EOF' 
#!/bin/sh
trap "Clean_up" 0 1 2 3 13 15 # EXIT HUP INT QUIT PIPE TERM

SHC_ROOT="/etc/hbase/shc"
HBASE_LAST_UPDATED_PATH="$SHC_ROOT/shc-hbase-last-updated"
SPARK_CONFIG_PATH="/etc/spark3/conf"
HBASE_CONFIG_PATH="/etc/hbase/conf"

Clean_up()
{
    exit_status=$?
    if [ ! "$exit_status" = 0 ]; then
        echo "Connector HBase Cron: script failed. Exiting with code $exit_status."
    fi
    exit "$exit_status"
}

Check_If_File_Exists_Cloud()
{
    sudo hdfs dfs -test -e /shc$1
    if [ $? -eq 0 ]; then
        return 0 
    else
        echo "Connector HBase Cron: File '$1' does not exist locally or on cloud. Check your storage account to make sure files exists."
        exit 1
    fi
} 

Download_Files()
{
    node=$(hostname)
    updated_cluster=$1
    echo "Connector HBase Cron: Begin download files on cloud storage to $node."
    sudo date -u

    # download new hbase-site.xml
    Check_If_File_Exists_Cloud /hbase-site.xml
    sudo rm -f $SPARK_CONFIG_PATH/hbase-site.xml
    sudo hdfs dfs -copyToLocal /shc/hbase-site.xml $SPARK_CONFIG_PATH
    sudo rm -f $HBASE_CONFIG_PATH/hbase-site.xml
    sudo cp $SPARK_CONFIG_PATH/hbase-site.xml $HBASE_CONFIG_PATH

    # update the HBase last updated time in this node to reflect most recent HBase scale
    sudo date -d "$(hdfs dfs -stat /shc/hbase-site.xml)" +"%s" | sudo tee $HBASE_LAST_UPDATED_PATH > /dev/null

    # if this is a secure cluster, download HBase hostname & ip mapping to local
    if [[ "$(hostname -f)" == *"securehadooprc"* ]]; then
        echo "Connector HBase Cron: Secure cluster, download HBase hostname & ip mapping. "

        Check_If_File_Exists_Cloud /hbase-hostname
        sudo rm -f $SHC_ROOT/hbase-hostname
        sudo hdfs dfs -copyToLocal /shc/hbase-hostname $SHC_ROOT/hbase-hostname

        Check_If_File_Exists_Cloud /hbase-etc-hosts
        sudo rm -f $SHC_ROOT/hbase-etc-hosts
        sudo hdfs dfs -copyToLocal /shc/hbase-etc-hosts $SHC_ROOT/hbase-etc-hosts
    fi

    echo "Connector HBase Cron: Files download to local successfully. "
    exit 0
}

Check_If_File_Exists_Cloud /

if [ ! -f $HBASE_LAST_UPDATED_PATH ]; then
    echo "======== Connector HBase Cron: Initial Set up. ========"
    Download_Files
else
    # check if hbase cluster has been scaled. If so, download new hbase-site.xml
    Check_If_File_Exists_Cloud /hbase-site.xml
    hdfs_last_updated=$(date -d "$(hdfs dfs -stat /shc/hbase-site.xml)" +"%s")
    local_last_updated=$(sudo cat $HBASE_LAST_UPDATED_PATH)

    if [[ $hdfs_last_updated > $local_last_updated ]]; then
        echo "======== Connector HBase Cron: HBase scaled up. ========"
        Download_Files
    fi
fi
EOF
}

# Add spark cron helper script on node
# If secure cluster, check /etc/hosts file to make sure HBase IP mapping always exists
Build_Spark_Cron_Script()
{
    echo "Connector Spark: Adding Spark cron helper script to $node."

    sudo rm -f $SPARK_CRON_SCRIPT_PATH
    sudo tee $SPARK_CRON_SCRIPT_PATH &>/dev/null <<'EOF' 
#!/bin/sh
trap "Clean_up" 0 1 2 3 13 15 # EXIT HUP INT QUIT PIPE TERM

SHC_ROOT="/etc/hbase/shc"
SPARK_CONFIG_PATH="/etc/spark3/conf"
HBASE_CONFIG_PATH="/etc/hbase/conf"
SPARK_LAST_UPDATED_PATH="$SHC_ROOT/shc-spark-last-updated"
HBASE_LAST_UPDATED_PATH="$SHC_ROOT/shc-hbase-last-updated"

Clean_up()
{
    exit_status=$?
    sudo rm -f $SHC_ROOT/tmp-etc-hosts-copy
    if [ ! "$exit_status" = 0 ]; then
        echo "Connector Spark Cron: Connector file edit triggered & failed. Exiting with code $exit_status."
    fi
    exit "$exit_status"
}

Check_If_File_Exists_Cloud()
{
    sudo hdfs dfs -test -e /shc$1
    if [ $? -eq 0 ]; then
        return 0 
    else
        echo "Connector Spark Cron: File '$1' does not exist locally or on cloud. Check your storage account to make sure files exists."
        exit 1
    fi
} 

Check_If_File_Exists_Locally()
{
    sudo test -e $SHC_ROOT$1

    # if doesn't exist locally, check if exist on cloud and try to download from there
    if [ ! $? -eq 0 ]; then
        Check_If_File_Exists_Cloud $1
        if [ $? -eq 0 ]; then
            sudo hdfs dfs -copyToLocal $1 $SHC_ROOT$1
        fi
    fi
}

Edit_Files()
{
    node=$(hostname)
    updated_cluster=$1
    sudo date -u
    echo "Connector Spark Cron: Begin editing /etc/hosts files. "

    # make edits to /etc/hosts file
    Check_If_File_Exists_Locally /hbase-hostname
    Check_If_File_Exists_Locally /hbase-etc-hosts
    sudo cp /etc/hosts $SHC_ROOT/tmp-etc-hosts-copy
    sudo cat $SHC_ROOT/hbase-hostname | xargs -i sudo sed -i '/{}/d' $SHC_ROOT/tmp-etc-hosts-copy 
    sudo bash -c 'sudo cat /etc/hbase/shc/hbase-etc-hosts >> /etc/hbase/shc/tmp-etc-hosts-copy' 
    sudo cp $SHC_ROOT/tmp-etc-hosts-copy /etc/hosts

    # update spark last updated time = most recent hbase scale
    # Indicating the timestamp of the most recent HBase cluster information
    sudo cat $HBASE_LAST_UPDATED_PATH | sudo tee $SPARK_LAST_UPDATED_PATH > /dev/null

    echo "Connector Spark Cron: Files edited successfully. "
    exit 0
}

if [ ! -f $SPARK_LAST_UPDATED_PATH ]; then
    echo "======== Connector Spark Cron: Initial Set up. ========"
    Edit_Files spark
fi

# check timestamp for spark last update with hbase update
# if hbase timestamps is more recent, indicates hbase scaled up, thus need to edit /etc/hosts file
hbase_last_updated=$(sudo cat $HBASE_LAST_UPDATED_PATH)
spark_last_updated=$(sudo cat $SPARK_LAST_UPDATED_PATH)
Check_If_File_Exists_Locally /hbase-hostname

if [[ $hbase_last_updated > $spark_last_updated ]]; then
    echo "======== Connector Spark Cron: HBase Scaled ========"
    Edit_Files hbase
# check /etc/hosts file to see if hbase cluster name exists, if not, spark cluster has been scaled
elif ! grep -q $(sudo cat $SHC_ROOT/hbase-hostname) /etc/hosts ; then
    echo "======== Connector Spark Cron: Spark Scaled ========"
    Edit_Files spark
fi

EOF
}

SetUp_Cron_Job()
{
    # update crontab, remove previous shc cron if exists
    sudo crontab -l | sed -e "/$CRON_SCRIPT_NAME/d" > /tmp/shc-tmpcron
    sudo crontab /tmp/shc-tmpcron

    # if spark cluster is secure update crontab, run spark script every mins by default
    if [[ "$(hostname -f)" == *"securehadooprc"* ]]; then
        echo "Connector Spark: Secure cluster, set up Spark cron. Frequency = $SPARK_CRON_TIME."
        (sudo crontab -l ; echo "$SPARK_CRON_TIME sh $SPARK_CRON_SCRIPT_PATH >> $CRON_LOG_PATH 2>&1")| sudo crontab -
    else
         echo "Connector Spark: Not a secure cluster, will not set up Spark cron."
    fi

    # if user specifies to set up HBase automatic check, update crontab
    if [ ! $1 -eq 0 ]; then
        echo "Connector Spark: User specified to set up HBase cron. Frequency = $HBASE_CRON_TIME."
        (sudo crontab -l ; echo "$HBASE_CRON_TIME sh $HBASE_CRON_SCRIPT_PATH >> $CRON_LOG_PATH 2>&1")| sudo crontab -
    else
         echo "Connector Spark: No HBase cron set up specified by user."
    fi
}

# ============================= MAIN =======================================

node=$(hostname)
echo "Connector Spark: Set up begins on $node..."

# set default cron job time
SPARK_CRON_TIME="*/1 * * * *"
HBASE_CRON_TIME=0

# get user specified cron job time if any
while getopts "s::h::" opt
do
    case "$opt" in
        s ) SPARK_CRON_TIME="$OPTARG" ;;
        h ) HBASE_CRON_TIME="$OPTARG" ;;
        ? )
            Help
            exit 0
            ;;
    esac
done

echo "Connector Spark: Spark cron parameter = $SPARK_CRON_TIME."
echo "Connector HBase: HBase cron parameter = $HBASE_CRON_TIME."

# check if HBase side script has been ran to create /shc directory
sudo hdfs dfs -test -e /shc
if [ ! $? -eq 0 ]; then
    echo "Connector Spark: /shc does not exist. Make sure you run HBase side script first."
    exit 1
fi

sudo mkdir -p $SHC_ROOT
Build_HBase_Cron_Script
Build_Spark_Cron_Script

# run hbase helper script at least once to set up files
sudo touch $CRON_LOG_PATH
sh $HBASE_CRON_SCRIPT_PATH >> $CRON_LOG_PATH 2>&1

# check if need to set up automatic hbase scaling activity
if [ $HBASE_CRON_TIME -eq 0 ]; then
    echo "Connector Spark: HBase scaling automatic checks disabled."
    SetUp_Cron_Job 0
else
    SetUp_Cron_Job 1
fi


echo "Connector Spark: Set up completed successfully. "
exit 0

