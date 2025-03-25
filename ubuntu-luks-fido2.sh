#/bin/bash

trap "echo 'interruption not possible'" INT

# check that command exists
check_command() {
    if command -v "$1" &> /dev/null
    then
        return 0   # true
    fi

    return 1   # false
}

# check that an op was successful,
# otherwise print error and exit
check_operation(){
	if [ "0" != "$?" ]; then
		echo "$1"
		exit 1
	fi
}

# tempory keyfile location
NEWKEYFILE="$HOME/newkey.${RANDOM}.tmp"

echo "IMPORTANT this script will use yubikey fido2"
echo "It will also delete luks keyslot 0 and overwrite luks keyslot 1"

read -p "Do you want to continue? (y/N) " SURE
if [ "Y" != "$SURE" ] && [ "y" != "$SURE" ]; then
	exit 1
fi

# find luks partition
echo "Searching for luks partition..."
LUKSUUID="$(lsblk -f -o "UUID,FSTYPE" | grep crypto_LUKS | awk -F " " '{print $1}')"

lsblk -l -o "NAME,UUID" | grep -q "$LUKSUUID"
check_operation "Could not find UUID=$LUKSUUID"

LUKSDEV="$(lsblk -l -o "NAME,UUID" | grep "$LUKSUUID" | awk -F " " '{print $1}')"

echo "Found luks device UUID=${LUKSUUID} path is /dev/${LUKSDEV}"

# get luks password
LUKSOLDPASSWD=$(/lib/cryptsetup/askpass "Please enter old boot password: ")

# test luks password
echo "$LUKSOLDPASSWD" | cryptsetup luksOpen --test-passphrase UUID="${LUKSUUID}"
check_operation "Unable to open luks device"

# dump infos BEFORE doing anything
echo "$LUKSOLDPASSWD" | cryptsetup luksDump UUID="${LUKSUUID}" 

echo "This operation will enroll fido2 from your yubikey"
echo "and remove keyslot 0 from your luks device and also will"
echo "overwrite your keyslot 1 from your luks devive"

read -p "Do you want to continue? (y/N) " SURE
if [ "Y" != "$SURE" ] && [ "y" != "$SURE" ]; then
	exit 1
fi

# install yubikey packages
if ! check_command "fido2-token"; then
    echo "installing fido2-tools"

    apt update
    apt install -y fido2-tools
    check_operation "Unable to fido2-tools"
fi

# install jq
if ! check_command "jq"; then
    echo "install jq"

    apt update
    check_operation "Unable to install jq"

    apt install -y jq
    check_operation "Unable to install jq"
fi

# generate backup key
echo "Generating backup key..."

touch "$NEWKEYFILE"
check_operation "Unable to create keyfile"

chmod 600 "$NEWKEYFILE"
check_operation "Unable to set 600 to keyfile"

# random 2048 char (A-Z,a-z,0-9) keyfile
tr -dc A-Za-z0-9 </dev/urandom | head -c 2048 >> "$NEWKEYFILE"
check_operation "Unable to generate keyfile"

# kill slot 1
echo "$LUKSOLDPASSWD" | cryptsetup luksKillSlot UUID="${LUKSUUID}" 1

# add backup key to slot 1
echo "$LUKSOLDPASSWD" | cryptsetup luksAddKey --new-key-slot 1 UUID="${LUKSUUID}" "$NEWKEYFILE"
check_operation "Unable to add backup key to luks device"

# test that the backup key works!
cryptsetup luksOpen --key-file "$NEWKEYFILE" --test-passphrase UUID="${LUKSUUID}"
check_operation "Unable to use backup key!!!"

# enroll fido2 yubikey
YUBIKEYDEV=$(fido2-token -L | awk -F ":" '{print $1}')

while [ "${YUBIKEYDEV}" == "" ]; do
    echo "unable to find yubikey, please insert yubikey and please enter"
    read 
    YUBIKEYDEV=$(fido2-token -L | awk -F ":" '{print $1}')
done

echo "found yubikey at ${YUBIKEYDEV}"

fido2-token -S -u "${YUBIKEYDEV}"

echo "enrolling yubikey"

systemd-cryptenroll --unlock-key-file="${NEWKEYFILE}" --fido2-device="${YUBIKEYDEV}" --fido2-with-client-pin=yes --fido2-with-user-presence=no --fido2-with-user-verification=yes "/dev/${LUKSDEV}"
check_operation "Unable to enroll yubikey!!!"

fido2-token -D -u "${YUBIKEYDEV}"

# update initram to use dracut with fido2 support
OLDLINE=$(grep -F "UUID=${LUKSUUID}" /etc/crypttab | grep -v -F 'fido2-device=auto')
NEWLINE=$(echo "$OLDLINE" | awk -F " " '{print $1 " " $2 " " $3}')
OPTIONS=$(echo "$OLDLINE" | awk -F " " '{print $4}')

if [ "$OPTIONS" == "" ]; then
    NEWLINE="$NEWLINE fido2-device=auto"
else
    NEWLINE="$NEWLINE ${OPTIONS},fido2-device=auto"
fi

# check if we need to install fido2-device=auto
if [ "$OLDLINE" != "" ]; then
	echo "replacing '${OLDLINE}' with '${NEWLINE}'"

	sed -i "s&${OLDLINE}&${NEWLINE}&g" "/etc/crypttab"
	check_operation "Unable to update /etc/crypttab"
fi

mkdir /etc/dracut.conf.d
echo 'hostonly="yes"' > /etc/dracut.conf.d/hostonly.conf

apt update -qq
apt install -y dracut
check_operation "Unable to install dracut"

# disable keyslot 0
cryptsetup luksKillSlot --key-file "$NEWKEYFILE" UUID="${LUKSUUID}" 0
check_operation "Unable to delete old password"

# move backup file to readable location
mv "$NEWKEYFILE" "${HOME}/backup.key"

