# SAP Automated Start/Stop Controll 

This script allows the automated start/stop on a system boot and shutdown. The package contains the main script **saprunctrl.sh**, a config file called **saprunctrl.conf** (not currently used) and the systemd init file **saprunctrl.service**.  

## Usage ##
1. After the install the service needs to be enabled `systemctl enable saprunctrl.service` 
1. The main script takes two inputs: 
    1. start, status and stop 
    1. log level [0 - error, 1 - info(default), 2 - trace, 3 - debug]
1. The **saprunctrl** script will check and start the **startsapsrv** if it is not running and will determine all the system ID's and system numbers for what to start. 
1. The start/stop order are based on the setting for instance in the **Host Agent**
1. Currently only supports SAP HANA and Sybase based system and currently has only been a single host. 

## Known Issues ##

 1. when starting/stopping a HANA DB the currently return status is not correct. If a `saprunctrl status` is run then the proper status is reported. 

## Features ##

- [ ] Support using a AWS tag to control if the autostart runs at startup 
- [ ] Use the saprunctrl.conf files to set some of the values 
- [ ] Push status information to Cloudwatch or an DynamoDB table
