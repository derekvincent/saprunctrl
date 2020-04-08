#!/bin/bash
## Logic:

## 1. Set required vairables 
## 
## 2. Check to make sure SAPHostAgent is running
##    - saphostctrl -nr 99 -function Ping 
## 2. Check the DB type and status
##    - saphostctrl -nr 99 -function ListDatabases 
##    - Fetch the Database Name (SID) - Status (Running/Stopped) - Type (syb)
## 3. If the db is not running start it 
##    - saphostctrl -nr 99 -function StartDatabase -dbname NPL -dbtype syb
## 4. Get a list of the SAP instances 
##    - saphostctrl -nr 99 -function ListInstances
## 5. Figure out what SAP instance is what - currently need to look at profiles 
##    - ./sapcontrol -nr 00 -function GetInstanceProperties | grep INSTANCE_NAME | awk -F, '{print $3}'
##    - Return the instance Type 

##
## Data Requirments 
## Type                 Source
## ------------------------------------------------
## SID                  saphostctrl -ListInstances / -ListDatabases   
## Hostname             saphostctrl -ListDatabases
## System Number        saphostctrl -ListInstances / -ListDatabases
## System Type          Determined either SAP or None
## Instance Type        saphostctrl -ListDatabases 
## Priority             sapcontrol -GetSystemInstanceList
## Status               saphostctrl -ListDatabases / sapcontorl GetProcessList 

HOSTAGENT_DIR="/usr/sap/hostctrl/exe"
SAPHOSTCTRL="${HOSTAGENT_DIR}/saphostctrl"
SAPCONTROL="${HOSTAGENT_DIR}/sapcontrol"

## Instance Array 
## Hostname, SID, System Number, System Type, Instance Type, Priority, Status 
declare -a INSTANCES=()
## 

check_hostagent()
{
    ## Verify that the SAP Host Agent is running. 
    agent_running=$(${SAPHOSTCTRL} -nr 99 -function Ping | awk '{print $1}')
    
    if [[ -z "$agent_running" ]]; then
        log_error "ERROR: HOSTAGENT CHECK: saphostctrl not found."
        exit 1
    fi 

    if [[ "$agent_running" == "FAILED" ]]; then
        log_error "ERROR: HOSTAGENT CHECK: Host Agent is not running."
        exit 1
    fi

    log_info "HOSTAGENT CHECK: Host Agent is running."

}

get_database()
{
    local database_header
    local database_detail
    local db_hostname
    local db_vendor
    local db_type
    local db_name
    local db_status

    database_header=$(${SAPHOSTCTRL} -nr 99 -function ListDatabases | head -1 | tail -1)
    database_detail=$(${SAPHOSTCTRL} -nr 99 -function ListDatabases | head -2 | tail -1)

    db_hostname=$(echo "$database_header" | awk -F',' '{print $2}' | awk -F: '{print $2}'| sed -e 's/^[[:space:]]*//')
    db_vendor=$(echo "$database_header" | awk -F',' '{print $3}' | awk -F: '{print $2}'| sed -e 's/^[[:space:]]*//')
    db_type=$(echo "$database_header" | awk -F',' '{print $4}' | awk -F: '{print $2}'| sed -e 's/^[[:space:]]*//')
    db_name=$(echo "$database_detail" | awk -F',' '{print $1}' | awk -F: '{print $2}'| sed -e 's/^[[:space:]]*//')
    db_status=$(echo "$database_detail" | awk -F',' '{print $2}' | awk -F: '{print $2}'| sed -e 's/^[[:space:]]*//')
    priority=0.3

    log_debug "GET DATABASE: Found ${db_hostname},${db_name},${sysnr},${db_vendor},${db_type},${priority},${db_status^^}"
    if [ "$db_type" == 'hdb' ]; then 
        db_name=$(echo "$db_name" | cut -d@ -f2)
        local instance
        mapfile -t instance < <(${SAPHOSTCTRL} -nr 99 -function ListInstances | awk -F, '{print $1}' | awk -F: '{print $2}' |awk -F' - ' 'BEGIN{OFS=",";} {print $1,$2,$3}')
        if (( ${#instance[@]} ))
        then
            log_debug "GET DATABASE: HANA instances details ${instance[@]}"
            for return_field in "${instance[@]}"
            do
                local sid
                sid=$( echo "${return_field}" | cut -d, -f1)  
                if [ "${db_name}" == $sid ]
                then                     
                    sysnr=$( echo "${return_field}" | cut -d, -f2) 
                    local return_status
                    check_instance_status $sid $sysnr return_status
                    log_debug "GET DATABASE: Returned HANA status: ${return_status}"
                    db_status=$return_status
                fi
            done
        fi


    fi

    ## Upsert the Instance array for with th DB
    local instance="${db_hostname},${db_name},${sysnr},${db_vendor},${db_type},${priority},${db_status^^}"
    log_debug "GET DATABASE: Upsert Record ${db_hostname},${db_name},${sysnr},${db_vendor},${db_type},${priority},${db_status^^}"
    upsert_instances "${instance}"


    log_trace "GET DATABASE: Hostname: $db_hostname, Vendor: $db_vendor, Type: $db_type, Name: $db_name, Priority: $priority Status: $db_status"

}

upsert_instances()
{
    ## Check the key (Hostname, System ID, and System Number) and updates the records
    ## Input is a full instance record 
    log_debug "UPSERT: Instances Input Upsert: $1"
    local input_record=$1 
    local input_key
    input_key=$( echo "${input_record}" | cut -d, -f 1-3)
    local update="N"

    for i in in "${!INSTANCES[@]}"
    do
        record_key=$( echo "${INSTANCES[i]}" | cut -d, -f 1-3 )
        if [[ ${input_key} = "${record_key}" ]]; then 
            log_debug "UPSERT: Existing Record Found --> ${record_key}"
            INSTANCES[i]="${input_record}"
            update="Y"
        fi
    done        
    if [ $update == "N" ]; then
        INSTANCES+=("${input_record}")
    fi

    log_debug "UPSERT: Instances After Upsert: ${INSTANCES[*]}"
}


get_instances() 
{
    ## Returns an array of SAP instances with SID, System Number and hostname 
    local instances
    mapfile -t instances < <(${SAPHOSTCTRL} -nr 99 -function ListInstances | awk -F, '{print $1}' | awk -F: '{print $2}' | awk -F' - ' 'BEGIN{OFS=",";} {print $1,$2,$3}')
    log_trace "GET INSTANCES: Found ${#instances[@]} - ${instances[*]}"
    if (( ${#instances[@]} ))
    then
        for instance in "${instances[@]}"
        do
            log_debug "GET INSTANCE: Instance: ${instance}"
            IFS=',' read -ra record <<< "${instance}"
            local sid
            local sysnr
            local hostname

            sid=${record[0]// }
            sysnr=${record[1]// }
            hostname=${record[2]// }
            local system_type=""
            local priority=""
            local return_status=""

            check_instance_status "$sid" "$sysnr" return_status
            log_debug "GET INSTANCES: Instance Status for $sid sysnr: $sysnr is $return_status"
            local instance_list
            mapfile -t instance_list < <(${SAPCONTROL} -nr "${sysnr}" -function GetSystemInstanceList | tail -n +6 | awk -F', ' 'BEGIN{OFS=",";} {print $1,$2,$5,$6,$7}')
            
            log_trace "GET INSTANCES: Found ${#instance_list[@]} - ${instance_list[*]}"
            if (( ${#instance_list[@]} )) ; then 

                for detail in "${instance_list[@]}" 
                do
                    log_debug "GET INSTANCES: Instance Detail: ${detail}"
                    if [[ "$detail" != *"HDB"* ]]; then
                        log_debug "GET INSTANCES - DETAILS: Match Value:  $hostname,$((10#$sysnr)) Record: $( echo "${detail}" | cut -d, -f 1-2)"
                        if [[ "$hostname,$((10#$sysnr))" == $( echo "${detail}" | cut -d, -f 1-2) ]]; then
                            local priority
                            local types
                            priority=$( echo "${detail}" | cut -d, -f3)
                            types=$( echo "${detail}" | cut -d, -f4)
                            log_debug "GET INSTANCES - DETAILS: Instance Type: ${types}"
                            if [[ ${types} == *"MESSAGESERVER|ENQUE"* ]]; then
                                system_type="ASCS"
                            elif [[ ${types} == *"ABAP"* ]]; then
                                system_type="DIALOG"
                            fi
                            local con_status
                            local status
                            status=$( echo "${detail}" | cut -d, -f5)
                            log_debug "GET INSTANCES - DETAILS: Instance Pre-Status: ${status}"
                            convert_instance_status "$status" con_status
                            log_debug "GET INSTANCES - DETAILS: Instance Post-Status: ${con_status}"
                            upsert_instances "$hostname,$sid,$sysnr,SAP,$system_type,$priority,$con_status"
                        fi
                    fi
                    
                done

            fi            
        done
    fi
}

convert_instance_status()
{
    ## Converts SAP GREEN/YELLOW/GRAY
    local __retvalue=$2
    local input_status=$1
    local status=""
    log_debug "CONVERT INSTANCE STATUS: CONVERT STATUS: Input Stauts: ${input_status}"
    if [[ "$input_status" ]]; then 
        case "$input_status" in
            YELLOW)
                status="STARTING"
                ;;
            GRAY)
                status="STOPPED"
                ;;
            GREEN)
                status="RUNNING"
                ;;
            RED)
                status="ERROR"
                ;;
        esac
    fi
    log_debug "CONVERT INSTANCE STATUS: Output Stauts: ${status}"
    eval "$__retvalue='$status'"
}

check_instance_status()
{
    local __retvalue=$3
    local status=""
    local sid=$1
    local sysnr=$2
    local cmd_return
    log_trace "INSTANCE STATUS: Checking the status of instance $sid - $sysnr"
    cmd_return=$(${SAPCONTROL} -nr "${sysnr}" -function GetProcessList)
    local rc=$?
    if [ $rc -eq 1 ]
    then
        if [[ $cmd_return == *"FAIL: NIECONN_REFUSED"* ]]
        then
            log_info "INSTANCE STATUS: Instance sapstartserv on ${sysnr} not running."
            cmd_return=$(${SAPCONTROL} -nr "${sysnr}" -function StartService "${sid}")
            if [[ $? -eq 1 ]]
            then 
                log_error "INSTANCE STATUS: Instance sapstartserv on ${sysnr} failed to start."   
                status="FAILED"
                #exit
            else
                status="STOPPED"
                log_info "INSTANCE STATUS: Instance sapstartserv on ${sysnr} started."   
            fi
        else   
            log_error "INSTANCE STATUS: GetProcessList returned an unknown error"   
        fi
        ## Sleep for 5 second to let the service finish the startup. 
        log_info "INSTANCE STATUS: Wait 5 seconda after ServiceStart."
        sleep 5
    elif [ $rc -eq 3 ]
    then
        log_trace "INSTANCE STATUS: Instance $sid - $sysnr is running."
        status="RUNNING"
    elif [ $rc -eq 4 ]
    then
        log_trace "INSTANCE STATUS: Instance $sid - $sysnr is stopped."
        status="STOPPED"
    else  
        log_trace "INSTANCE STATUS: Instance $sid - $sysnr is starting." 
        status="STARTING"
    fi
    eval "$__retvalue='$status'"
}

update_instance_status()
{
    if [[ -z $1 ]]
    then
        IFS=',' read -ra record <<< "$1"
        local host=${record[0]}
        local sid=${record[1]}
        local sysnr=${record[2]}
        local stype=${record[3]}
        local itype=${record[4]}
        local priority=${record[5]}
        local status=${record[6]}
        log_debug "UPDATE INSTANCE STATUS: Input Record --> ${record[*]}"
        ## If SAP or Hana based system the call the 'check_instance_status' function
        if [[ $stype = "SAP" ]] || [[ $stype = "HDB" ]]
        then
            local return_status
            check_instance_status "$sid" "$sysnr" return_status
            log_debug "UPDATE INSTANCE STATUS: $sid/$sysnr returned status $return_status"
            if [[ $status != return_status ]]
            then 
                upsert_instances "$host,$sid,$sysnr,$stype$,$itype,$priority,$return_status"
            fi
        elif [[ $stype = "SYB" ]]
        then
            local result_status
            log_trace "UPDATE INSTANCE STATUS - DATABASE START: Check Database $db_name status."
            result=$(${SAPHOSTCTRL} -nr 99 -function GetDatabaseStatus -dbname "${sid}" -dbtype "${itype}" -dbhost "${host}")
            result_status=$(echo "$result" | head -1)
            log_trace "UPDATE INSTANCE STATUS: Sybase result --> $result_status"
            if [[ $result_status = "Database Status: Running" ]]; then 
                db_status="RUNNING"
            else 
                db_status="STOPPED"
            fi

            if [[ $status != db_status ]]
            then
                upsert_instances "$host,$sid,$sysnr,$stype$,$itype,$priority,$db_status"
            fi        
        fi

    fi
}

start_database()
{
    for instance in "${INSTANCES[@]}"
    do
        IFS=',' read -ra record <<< "$instance"
        local host=${record[0]}
        local sid=${record[1]}
        local sysnr=${record[2]}
        local stype=${record[3]}
        local itype=${record[4]}
        local priority=${record[5]}
        local status=${record[6]}

        if [[ $stype != "SAP" ]] && [[ $status = STOPPED ]]
        then 
            local return_status
            if [[ $stype = "HDB" ]]
            then
                log_trace "START DATABASE: Starting HANA System SID: $sid  SYSNR: $sysnr."
                start_instance ${instance} return_status
            elif [[ $stype = "SYB" ]]
            then
                log_trace "DATABASE START: Starting $stype Database $sid."
                result=$(${SAPHOSTCTRL} -nr 99 -function StartDatabase -dbname "${sid}" -dbtype "${stype}" -dbhost "${host}")
                rc=$?
                log_debug "DATABASE START: Return from StartDatabase: $rc."
                if [ "$rc" -ne 0 ]; then 
                    log_error "DATABASE START: Database $sid failed to start: $result"
                else 
                    log_info "DATABASE START: Database $sid started."
                    return_status="RUNNING"
                fi                
            else
                log_error "START DATABASE: Database $stype not currently supported."
            fi
            upsert_instances "${record[0]},${record[1]},${record[2]},${record[3]},${record[4]},${record[5]},${return_status}"
        
        elif [[ $stype != "SAP" ]] && [[ $status = STARTING ]]
        then 
            (( i = 0 ))
            while [[ i -lt 12 ]]
            do
                local return_status
                log_debug "START DATABASE: Waiting while the database starts loop $i}"
                if [[ $stype = "HDB" ]]
                then
                    log_trace "START DATABASE: Starting HANA System SID: $sid  SYSNR: $sysnr."
                    check_instance_status "$sid" "$sysnt" return_status
                elif [[ $stype = "SYB" ]]
                then
                    echo 'Need to do something here.'
                fi
                upsert_instances "${record[0]},${record[1]},${record[2]},${record[3]},${record[4]},${record[5]},${return_status}"
                if [[ ${return_status} = RUNNING ]]
                then
                    log_debug "START DATABASE: Database has entered the state $return_stauts}" 
                    break
                fi

                sleep 10
                (( i++ ))

            done
        fi 
    done 
}

stop_database()
{
    for instance in "${INSTANCES[@]}"
    do
        IFS=',' read -ra record <<< "$instance"
        local host=${record[0]}
        local sid=${record[1]}
        local sysnr=${record[2]}
        local stype=${record[3]}
        local itype=${record[4]}
        local priority=${record[5]}
        local status=${record[6]}
        log_debug "STOP DATABASE: Preparing to stop database: $sid $stype $itype -"
        if [[ $stype != "SAP" ]] && [[ $status = "RUNNING" ]]
        then 
            local return_status
            if [[ $stype = "HDB" ]]
            then
                log_trace "STOP DATABASE: Starting HANA System SID: $sid  SYSNR: $sysnr."
                stop_instance ${instance} return_status
            elif [[ $stype = "SYB" ]]
            then
                log_trace "DATABASE START: Starting $stype Database $sid."
                result=$(${SAPHOSTCTRL} -nr 99 -function StopDatabase -dbname "${sid}" -dbtype "${stype}" -dbhost "${host}")
                rc=$?
                log_debug "DATABASE STOP: Return from StopDatabase: $rc."
                if [ "$rc" -ne 0 ]; then 
                    log_error "DATABASE STOP: Database $sid failed to stop: $result"
                    return_status="STOPPED"
                else 
                    log_info "DATABASE STOP: Database $sid stopped."
                    return_status="STOPPED"
                fi                
            else
                log_error "START DATABASE: Database $stype not currently supported."
            fi
            log_debug "STOP DATABASE: Outbound upsert ${record[0]},${record[1]},${record[2]},${record[3]},${record[4]},${record[5]},${return_status}"
            upsert_instances "${record[0]},${record[1]},${record[2]},${record[3]},${record[4]},${record[5]},${return_status}"
        fi 
    done 
}

start_instance()
{
    local instance=$1
    local __retvalue=$2
    if [[ ${instance} ]]
    then
        IFS=',' read -ra record <<< "$instance" 
        local host=${record[0]}
        local sid=${record[1]}
        local sysnr=${record[2]}
        local stype=${record[3]}
        local itype=${record[4]}
        local priority=${record[5]}
        local status=${record[6]}
        
        log_trace "START INSTANCE: Starting Instance: ${sid} - ${sysnr} type: ${itype}"
        local start_return
        start_return=$("${SAPCONTROL}" -nr "${sysnr}" -function StartWait 240 5)    
        local rc=$?
        if [[ $rc -eq 0 ]]
        then
            log_info "START INSTANCE: $itype instance $sid - $sysnr started."
            status="RUNNING"
        elif [[ $rc -eq 1 ]]
        then
            log_error "START INSTANCE: Error on Start: $start_return"
            status="ERROR"
        elif [[ $rc -eq 2 ]]
        then
            log_error "ERROR: START INSTANCE: Instance Start waiter timeout, instance ${sid} - ${sysnr} may be running."
            status="ERROR"
        fi
        eval "$__retvalue='$status'"
    fi
}

stop_instance()
{
    local instance=$1
    local __retvalue=$2
    if [[ ${instance} ]]
    then
        IFS=',' read -ra record <<< "$instance" 
        local host=${record[0]}
        local sid=${record[1]}
        local sysnr=${record[2]}
        local stype=${record[3]}
        local itype=${record[4]}
        local priority=${record[5]}
        local status=${record[6]}
        
        log_trace "STOP INSTANCE: Stopping Instance: ${sid} - ${sysnr} type: ${itype}"
        local start_return
        start_return=$("${SAPCONTROL}" -nr "${sysnr}" -function StopWait 120 5)    
        local rc=$?
        if [[ $rc -eq 0 ]]
        then
            log_info "STOP INSTANCE: $itype instance $sid - $sysnr stopped."
            status="STOPPED"
        elif [[ $rc -eq 1 ]]
        then
            log_error "STOP INSTANCE: Error on Stop: $start_return"
            status="ERROR"
        elif [[ $rc -eq 2 ]]
        then
            log_error "STOP INSTANCE: Instance Stop waiter timeout, instance ${sid} - ${sysnr} maybe stopped."
            status="ERROR"
        fi
        eval "$__retvalue='$status'"
    fi
}

stop_system()
{
    ##
    ## 1. Sort the INSTANCE array by the 'priority' column which is provided from
    ##    the SAP HostAgent as the defined start order. 
    ## 2. Loop over the sorted array 
    ## 3. If the Product is SAP (non-DB) and the instance is started call the 
    ##    stop_instance function to stop the SAP system. 
    ## 4. Get the return status of the stop request and call the upsert function
    ##    to update the global status. 
    ##

    if (( "${#INSTANCES[@]}" ))
    then
        local sorted
        mapfile -t sorted < <(printf "%s\n" "${INSTANCES[@]}" | sort -n -r -k6,6 -t,)
        log_debug "STOP SYSTEM: Stop Order: ${sorted[*]}"
        for instance in "${sorted[@]}"
        do
            IFS=',' read -ra record <<< "${instance}" 
            #local host=${record[0]}
            #local sid=${record[1]}
            #local sysnr=${record[2]}
            local stype=${record[3]}
            #local itype=${record[4]}
            #local priority=${record[5]}
            local status=${record[6]}
            if [[ ${stype} = SAP ]] && [[ ${status} = RUNNING ]]
            then
                local return_status
                stop_instance "${instance}" return_status
                log_trace "STOP SYSTEM: System ${record[1]}/${record[2]} stop status: ${return_status}"
                upsert_instances "${record[0]},${record[1]},${record[2]},${record[3]},${record[4]},${record[5]},${return_status}"
            fi
        done
    fi
}

start_system()
{
    ##
    ## 1. Sort the INSTANCE array by the 'priority' column which is provided from
    ##    the SAP HostAgent as the defined start order. 
    ## 2. Loop over the sorted array 
    ## 3. If the Product is SAP (non-DB) and the instance is stopped call the 
    ##    start_instance function to start the SAP system. 
    ## 4. Get the return status of the start request and call the upsert function
    ##    to update the global status. 
    ##

    if (( "${#INSTANCES[@]}" ))
    then
        local sorted
        mapfile -t sorted < <(printf "%s\n" "${INSTANCES[@]}" | sort -n -k6,6 -t,)
        log_debug "START SYSTEM: Start Order: ${sorted[*]}"
        for instance in "${sorted[@]}"
        do
            IFS=',' read -ra record <<< "${instance}" 
            #local host=${record[0]}
            #local sid=${record[1]}
            #local sysnr=${record[2]}
            local stype=${record[3]}
            #local itype=${record[4]}
            #local priority=${record[5]}
            local status=${record[6]}
            if [[ ${stype} = SAP ]] && [[ ${status} = STOPPED ]]
            then
                local return_status
                start_instance "${instance}" return_status
                log_trace "START SYSTEM: System ${record[1]}/${record[2]} start status: ${return_status}"
                upsert_instances "${record[0]},${record[1]},${record[2]},${record[3]},${record[4]},${record[5]},${return_status}"
            fi
        done
    fi
}

check_environment()
{
    echo 'Not here yet.'
    ## 
    ## Check if this an AWS enviornment (can support other later). 
    ## If so use a tag to control autostart in the case you do not want the
    ## SAP environment to start on boot. During an upgrade or crash debugging etc.
    ## 
    ## Also plan to support a dynamo DB update on start/stop for the running state of 
    ## the system.
    ##
}

## Prints the current status of the system
print_status(){

    printf "\\n%-30s %-4s %-3s %-5s %-8s %-4s %-8s \n" "Hostname" "SID" "SNR" "Prod" "Type" "Pri" "Status"
    printf "%s\\n" "====================================================================="
    for instance in "${INSTANCES[@]}"; do
        IFS=',' read -ra record <<< "$instance" 
        printf "%-30s %-4s %-3s %-5s %-8s %-4s %-8s \\n" "${record[0]}" "${record[1]}" "${record[2]}" "${record[3]}" "${record[4]}" "${record[5]}" "${record[6]}"
    done
}

#### 
## Logging 
###
colred='\033[0;31m' # Red
colgrn='\033[0;32m' # Green
colblu='\033[0;34m' # Blue
colpur='\033[0;35m' # Purple
colrst='\033[0m'    # Text Reset
 
verbosity=1

### verbosity levels
err_lvl=0
inf_lvl=1
trc_lvl=2
dbg_lvl=3

log_level=0

function log_trace () { log_level=$trc_lvl log_printer "${colblu}TRACE${colrst} - $*" ;}
function log_info ()  { log_level=$inf_lvl log_printer "${colgrn}INFO${colrst} -- $*" ;}
function log_debug () { log_level=$dbg_lvl log_printer "${colpur}DEBUG${colrst} - $*" ;}
function log_error () { log_level=$err_lvl log_printer "${colred}ERROR${colrst} - $*" ;}
log_printer()
{
        if [ $verbosity -ge "$log_level" ]; then
                datestring=$(date +"%Y-%m-%d %H:%M:%S")
                echo -e "$datestring - $*"
        fi
}

## SETUP FUNCTIONS 
## Call the base functions to discover all the instance data
setup_instances()
{
    check_hostagent
    get_database
    get_instances
}

## Starts the entire System
start()
{
    setup_instances
    start_database
    start_system
    print_status
}

## Stops the entire system
stop()
{
    setup_instances
    stop_system
    stop_database
    print_status
}

## Prints the Current System Status 
status()
{
    setup_instances
    print_status
}

### MAIN

if [[ $2 ]]
then
    verbosity=$2
fi


if [[ $1 ]]
then
    if [[ ${1^^} = "START" ]] 
    then
        echo "INFO: START SYSTEM"
        start
    elif [[ ${1^^} = "STOP" ]]
    then 
        echo "INFO: STOP SYSTEM"
        stop
    elif [[ ${1^^} = "STATUS" ]]
    then 
        echo "INFO: SYSTEM STATUS"
        status
    fi
else 
    ## Default with no parameters passed is Status
    echo "INFO: SYSTEM STATUS"
    status
fi
