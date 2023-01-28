#!/usr/bin/env bash

max_attempts=60
exit_code=0

# Allow a modification to systemd to push in the max number of check attempts
if [[ $1 -gt 0 ]]; then
    max_attempts=$1
fi

# Iterate all encrypted filesystems in /etc/crypttab
while IFS= read -r line; do
    device_name=$(echo "$line" | awk '{print $1}')
    device=$(echo "$line" | awk '{print $2}')
    if echo "$device" | grep -q -E "^UUID="; then
        uuid=$(echo "$device" | cut -d "=" -f 2)
        device="/dev/disk/by-uuid/$uuid"
    fi
    # Determine if said block device is LUKS of any type
    if cryptsetup isLuks "${device}" 2>/dev/null; then
        if [[ $device_name == "" ]]; then
            echo "Ignoring ${device} because we could not find a matching entry in /etc/crypttab"
            continue
        fi

        # This is a sanity check to make sure clevis is bound on this device, otherwise ignore it.
        if cryptsetup isLuks --type luks1 "${device}"; then
            if ! luksmeta show -d "${device}" | grep 'cb6e8904-81ff-40da-a84a-07ab9ab5715e' >/dev/null 2>&1; then
                echo "Ignoring LUKS1 device ${device} because it does not appear to have clevis bindings"
                continue
            fi
        elif cryptsetup isLuks --type luks2 "${device}"; then
            if ! cryptsetup luksDump "${device}" | grep ': clevis$' >/dev/null 2>&1; then
                echo "Ignoring LUKS2 device ${device} because it does not appear to have clevis bindings"
                continue
            fi
        else
            echo "WARNING: ${device} is a luks device but not luks1/luks2? skipping."
            continue
        fi

        i=0
        until [[ ${i} -gt ${max_attempts} ]]; do
            i=$((i + 1))
            echo "Attempting to unlock: clevis luks unlock -d \"${device}\" -n \"${device_name}\""
            clevis luks unlock -d "${device}" -n "${device_name}"
            result=$?
            if [[ $result -eq 0 ]] || [[ $result -eq 5 ]]; then
                # 0 means it worked, 5 means it is already unlocked
                break
            fi
            sleep 1
        done

        if [[ $result -eq 0 ]]; then
            echo "Successfully unlocked ${device} after ${i} attempts"
        elif [[ $result -eq 5 ]]; then
            echo "Device ${device} was already unlocked"
        else
            echo "ERROR: Unable to unlock device ${device} after ${i} attempts"
            exit_code=1
        fi
    fi
done < <(grep -E -v "^#" /etc/crypttab)

exit ${exit_code}
