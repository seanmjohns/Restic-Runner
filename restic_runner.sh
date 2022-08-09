#!/bin/bash

#Place the following cron entries in your crontab:
# m h   dom mon dow   command
#0 21 * * * sudo -u sean /home/sean/.restic_runner/restic_runner.sh --force
#@reboot sudo -u sean /home/sean/.restic_runner/restic_runner.sh
#Change the user to your username and change the script to the correct location that you choose.

#You will need to update the following variables:
# 1. B2_ACCOUNT_ID
# 2. B2_ACCOUNT_KEY
# 3. B2_BUCKET_NAME
# 4. RESTIC PASSWORD
# 5. BASEDIR (update this to the place where you put the directory)
# 6. TIME_TO_BACKUP_SECONDS (Update this to the number of seconds after 12 AM at which time the backup should run automatically [only applies if you want automatic backups])

#To have this run automatically:
# The first cron job will run the backup script whenever you want it to (set it to the time you want to run the backup daily).
#  The --force option will force the script to backup even if there was a backup in the last 24 hours.
# The second cron job will run the script on boot. When it runs, it will check to see if there was a backup since the last time the backup was supposed to run.
#  Uses the previous log files to determine the time last run.

#This allows for sending messages to the user that started the gui. Put your userid (output from $(id -u)) in place of the number here.
export XDG_RUNTIME_DIR=/run/user/1000

#Notification icons
SUCCESSICON="/usr/share/icons/gnome/32x32/emblems/emblem-default.png"
FAILUREICON="/usr/share/icons/gnome/32x32/status/dialog-error.png"

#Backblaze b2 creds/env vars
export B2_ACCOUNT_ID=
export B2_ACCOUNT_KEY=
export B2_BUCKET_NAME=
export RESTIC_REPOSITORY=b2:$B2_BUCKET_NAME
export RESTIC_PASSWORD=

#This is the time, in seconds since 12:00 AM (your machine's time), that the backup should occur
#For example, to backup at 9:00 PM, the seconds would be 21 hours * 60 minutes/hr * 60 seconds/min = 75600 seconds
#This needs to match the time you have set for your first restic-runner cron job (the one that backs up the computer at the specific time when the machine is running)
TIME_TO_BACKUP_SECONDS=75600

#Restic-runner files/dirs
BASEDIR=
LOGDIR=${BASEDIR}/logs
EXCLUDECONFIG=${BASEDIR}/exclude.config
INCLUDECONFIG=${BASEDIR}/include.config

function createLog {

    echo "Creating new log"

    log_file_name="$LOGDIR/rr-$(date --iso-8601=s).log"
    echo "$log_file_name"
    touch $log_file_name

    #Send all output from this script to the new log file as well as stdout
    exec >> "$log_file_name" 2>&1

}

function manageLogs {

    echo "Managing previous logs"

    #Logs are stored in the following format
    #rr-[date/time].log
    #where [date/time] is in iso8601 format
    for log in $(find "$LOGDIR" -regextype posix-egrep -regex ".*rr-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}.log" -type f); do

        #check log
        log_filename=$(basename "$log")
        echo "$log_filename"

        date_length=$((${#log_filename}-7))
        date_iso8601=${log_filename:3:$date_length}
        file_date_seconds=$(date -d "$date_iso8601" "+%s")

        one_week_ago=$(($(date "+%s")-604800))

        if [[ $one_week_ago > $file_date_seconds ]]; then #This log has existed for more than a week
            echo "...Removed."
            rm "$log"
        fi

    done

}

function checkIfMissedBackup {

    OUTPUT_BEFORE_LOG_MADE=$OUTPUT_BEFORE_LOG_MADE"Checking for previous backups.\n"

    #need to determine if last backup was run
    #determine if the backup is supposed to run later today or if it was supposed to run earlier today (compare seconds since 12:00 AM)
    #If it was supposed to run this morning, use today's 12:00AM seconds to get seconds of scheduled date/time. Check for any backups at or after that time.
    #If it was supposed to run yesterday (runs later today), then use yesterday's 12:00AM seconds to get scheduled date/time. Check for any backups at or after that time.

    current_date_seconds_12AM=$(date --date=$(date "+%F") "+%s")
    current_time_seconds=$(date "+%s")
    current_time_since_midnight_seconds=$(($current_time_seconds-$current_date_seconds_12AM))

    export time_of_last_expected_backup=""

    one_day_ago_12AM=$((${current_date_seconds_12AM}-86400))

    if [[ $current_time_since_midnight_seconds > $TIME_TO_BACKUP_SECONDS ]]; then
        #Last backup was supposed to be earlier today
        export time_of_last_expected_backup=$((${current_date_seconds_12AM}+${TIME_TO_BACKUP_SECONDS}))
    else
        #Last backup was supposed to be yesterday
        export time_of_last_expected_backup=$((${one_day_ago_12AM}+${TIME_TO_BACKUP_SECONDS}))
    fi

    #Logs are stored in the following format
    #rr-[date/time].log
    #where [date/time] is in iso8601 format
    for log in $(find "$LOGDIR" -regextype posix-egrep -regex ".*rr-[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}.log" -type f); do

        #check log
        log_filename=$(basename "$log")
        OUTPUT_BEFORE_LOG_MADE=$OUTPUT_BEFORE_LOG_MADE"$log_filename..."

        date_length=$((${#log_filename} - 7))
        date_iso8601=${log_filename:3:$date_length}
        file_date_seconds=$(date -d "$date_iso8601" "+%s")

        OUTPUT_BEFORE_LOG_NAME=$OUTPUT_BEFORE_LOG_MADE"$file_date_seconds"

        if [[ $time_of_last_expected_backup < $file_date_seconds ]]; then
            return 1 #There was a previous backup since the last scheduled backup time
            OUTPUT_BEFORE_LOG_MADE=$OUTPUT_BEFORE_LOG_NAME"New Backup!\n"
        else 
            OUTPUT_BEFORE_LOG_MADE=$OUTPUT_BEFORE_LOG_MADE"Older Backup.\n"
        fi

    done

    createLog
    #Wont get here if there was a backup in the last 24 hours (will return 1 above) #No backups made in the last 24 hours, so make a new log createLog #Send to file all the previous stuff when checking for previous backups
    echo -e "$OUTPUT_BEFORE_LOG_MADE"

    return 0

}

function backup {

    restic_backup_status="Restic-Backup: Not Run." #This should never happen
    restic_check_status="Restic-Check: Not Checked." #This will happen if there is an error that occurred while backing up
    restic_forget_status="Restic-Forget: Not Run." #This will happen if there is an error in the above things.

    manageLogs #Manage all logs for previous backups

    error=0

    #If the backup failed recently due to a shutdown or otherwise, then the bucket is still locked. Unlock it
    restic unlock -r b2:Laptop-Ubuntu-Restic

    #Now backup
    restic backup --files-from=${INCLUDECONFIG} --exclude-file=${EXCLUDECONFIG} --verbose=20

    [[ $? = 0 ]] && error=false || error=true
    [[ $error = false ]] && restic_backup_status="Restic-Backup: Completed Successfully." || restic_backup_status="Restic-Backup: Error Occurred."
    echo "$restic_backup_status"

    #Only need to check if the backup was successful anyways
    if [[ $error = false ]]; then
        echo
        echo "Checking Backup Integrity."
        #Check to ensure the backup worked (on small backups, this should not use too many class B transactions)
        restic check --with-cache --no-lock --verbose=20
        [[ $? = 0 ]] && error=false || error=true
        [[ $error = false ]] && restic_check_status="Restic-Check: No Issues." || restic_check_status="Restic-Check: Issue Found."
        echo "$restic_check_status"
    fi

    #Dont prune old backups if there was an issue with this one
    if [[ $error = false ]]; then
        echo
        echo "Pruning old backups that are no longer needed"
        #Remove older snapshots that are no longer needed
        restic forget --verbose=20 --keep-last 20 \
            --keep-daily 7 \
            --keep-weekly 4 \
            --keep-monthly 6 \
            --keep-yearly 3 \
            --limit-upload 500 \
            --prune
        [[ $? = 0 ]] && error=false || error=true
        [[ $error = false ]] && restic_forget_status="Restic-Forget: Successful." || restic_forget_status="Restic-Forget: Error Occurred."
        echo "$restic_forget_status"
    fi

    #Notify user of the result
    #Use the appropriate icon (successful or not)
    [[ $error = false ]] && icon=$SUCCESSICON || icon=$FAILUREICON

    notify-send --icon=$icon "$restic_backup_status" "$restic_check_status $restic_forget_status"

}

function main {

    force=0

    for i in "$@"; do
        case $i in

            "-f" | "--force")
                #Force the backup to occur even if there was one in the last 24 hours
                force=1
                ;;

            "-h")
                echo "help"
                ;;

            *)
                echo "Illegal argument '$i'"
                exit
                ;;

        esac
    done

    checkIfMissedBackup
    recentBackup=$?

    if [[ $recentBackup -eq 1 ]]; then #There was a backup in the last 24 hours
        if [[ $force -eq 1 ]]; then #User wants to force a backup
            backup
        else
            echo "A backup was run at or since the scheduled time. Not running backup."
            exit
        fi
    else #This is a scheduled backup or a backup was missed
        backup
    fi

    exit 0

}

main "$@"
