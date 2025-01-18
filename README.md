# get-vms

This is a bash script that will provide the name, uuid, mac address and local ip address of all virtual box virtual machines running on your host, even if they're using a bridged network adapter over wifi.

## Pre-requisites

You must have the following installed on your system.

|Software|Installation Instructions|
|--|--|
|`nmap`|`sudo apt install nmap`|
|`virtualbox`|`sudo apt install virtualbox`|
|`wget`|`sudo apt install wget`|

## Setup

Copy and paste the following snippet into your terminal. It will do the following:

1. Create a directory for the script.
2. Download the script.
3. Make the script executable.
4. Add an alias to your bash configuration file for future use.
5. Reload your bash configuration file.

```
mkdir $HOME/.config/get-vms && \
wget -O $HOME/.config/get-vms/get-vms.sh https://raw.githubusercontent.com/GarlandKey/get-vms/refs/heads/dev/get-vms.sh && \
chmod +x $HOME/.config/get-vms/get-vms.sh && \
echo "alias get-vms='$HOME/.config/get-vms/get-vms.sh'" >> $HOME/.bashrc && \
source $HOME/.bashrc
```

## Run 

Type the following into the terminal:

```
get-vms
```
