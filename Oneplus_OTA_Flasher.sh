#!/bin/bash

# Set directory for extracted OTA images
OTA_DIR="./image_files"

# Check if directory exists; if not: create it
if [ ! -d "$OTA_DIR" ]; then
  mkdir -p "$OTA_DIR"
fi

# Create an array using the filenames of  the .bin & .img files in the directory
img_files=()
for file in "$OTA_DIR"/*; do
  if [[ "$file" == *.img || "$file" == *.bin ]]; then
    img_files+=("$file")
  fi
done

# If the array is empty alert user to add files in order to use Erase & Flash functions
if [ ${#img_files[@]} -eq 0 ]; then
  echo "No .bin or .img files found in $OTA_DIR."
  echo "Please add files to use the Erase & Flash functions."
  echo "" # Spacer
fi

# Function to check if device is connected in fastbootd
enter_fastbootd_mode() {
  echo "Checking for a connected device in fastbootd mode..."
  fastboot devices | grep -q "fastboot"

  # Failed to find a device in fastbootd mode
  if [ $? -ne 0 ]; then
    echo "Device not found in fastbootd mode"
    echo "Attempting to reboot into fastbootd mode..."

    adb reboot fastboot
    fastboot wait-for-device 2>/dev/null
    # "2>/dev/null" Suppresses an error that seems to be a false positive

    # Re-check for device in fastbootd mode
    fastboot devices | grep -q "fastboot"

    # Failed to pass re-check of fastbootd mode
    if [ $? -ne 0 ]; then
      echo "Device failed to reboot into fastbootd mode."
      return 0
    else
      echo "Device found in fastbootd mode"
      return 1
    fi
  else
    echo "Device found in fastbootd mode."
    return 1
  fi
}

# Function to check if device is in bootloader mode
enter_bootloader_mode() {
  # Check if device is in fastbootd mode first
  if ! fastboot devices | grep -q "fastboot"; then
    echo "Error: Device is not in fastbootd mode. Switching to fastbootd mode first."
    enter_fastbootd_mode
  fi

  echo "Checking for a connected device in bootloader mode..."
  fastboot devices | grep -q "bootloader"

  # Failed to find a device in bootloader mode
  if [ $? -ne 0 ]; then
    echo "Device not found in bootloader mode."
    echo "Attempting to reboot into bootloader mode..."

    fastboot reboot bootloader
    # fastboot wait-for-device 2>/dev/null
    # "2>/dev/null" Suppresses an error that seems to be a false positive
    while ! fastboot devices; do
      sleep 1
    done

    # Re-check for device in bootloader mode
    fastboot devices | grep -q "bootloader"

    # Failed to pass re-check of bootloader mode
    if [ $? -ne 0 ]; then
      echo "Device failed to reboot into bootloader mode."
      return 0
    else
      echo "Device found in bootloader mode."
      return 1
    fi
  else
    echo "Device found in bootloader mode."
    return 1
  fi
}

# Function to get the active partition (_a or _b)
get_active_partition() {
  echo "Checking for an active slot (_a or _b)..."

  # Check for ADB connection
  adb_state=$(adb get-state 2>/dev/null)
  if [[ "$adb_state" == "device" || "$adb_state" == "recovery" ]]; then
    echo "ADB mode detected: $adb_state"
    # Try to get the active slot using ADB
    active_slot=$(adb shell getprop ro.boot.slot_suffix | tr -d '_' | tr -d '\r')
  else
    echo "ADB not available. Device state: $adb_state"
  fi

  # Check for fastboot mode
  fastboot_state=$(fastboot devices 2>/dev/null)
  if [[ "$fastboot_state" == *"fastbootd"* ]]; then
    echo "Fastboot mode detected."
    # Try to get the active slot using fastboot
    active_slot=$(fastboot getvar current-slot 2>&1 | grep -oE 'a|b' | head -n 1)
  fi

  # Check for bootloader mode
  bootloader_state=$(fastboot devices 2>/dev/null)
  if [[ "$bootloader_state" == *"bootloader"* ]]; then
    echo "Bootloader mode detected."
    # Try to get the active slot using fastboot
    active_slot=$(fastboot getvar current-slot 2>&1 | grep -oE 'a|b' | head -n 1)
  fi

  if [[ "$active_slot" == "a" || "$active_slot" == "b" ]]; then
    ACTIVE_SUFFIX="_$active_slot"
    echo "Active suffix: $ACTIVE_SUFFIX"
  else
    ACTIVE_SUFFIX=""
    echo "No active A/B slot detected."
  fi
}

# Function to all the user to select which partition they want as 'active'
select_active_partition() {
  echo "Select the active slot:"
  echo "1. _a"
  echo "2. _b"
  echo "3. Clear active slot"

  read -p "Enter your choice (1/2/3): " choice

  case $choice in
  1) ACTIVE_PARTITION="_a" ;;
  2) ACTIVE_PARTITION="_b" ;;
  3)
    echo "Clearing active slot."
    unset ACTIVE_PARTITION
    ;;
  *)
    echo "Invalid choice. Defaulting to _a."
    ACTIVE_PARTITION="_a"
    ;;
  esac

  if [ -z "$ACTIVE_PARTITION" ]; then
    echo "Active slot cleared."
  else
    echo "Active slot set to: $ACTIVE_PARTITION"
  fi
}

erase_active_partition() {
  if [ -z $ACTIVE_PARTITION ]; then
    echo "This will erase the devices's currently in use slot"
    read -p "Do you want to continue? (y/n) " choice
  else
    echo "This will erase slot $ACTIVE_PARTITION"
    read -p "Do you want to continue? (y/n) " choice
  fi

  case "$choice" in
  y | Y) ;;
  n | N) return ;;
  *) echo "Invalid choice. Exiting." && return ;;
  esac

  if [ -n "$ACTIVE_PARTITION" ]; then
    echo "Erasing all partitions on slot $ACTIVE_PARTITION:"
  else
    echo "Erasing all partitions on the active slot:"
  fi

  for img_file in "${img_files[@]}"; do
    partition=$(basename "$img_file" .img)
    partition_name="${partition}${ACTIVE_PARTITION}"

    echo "Erasing $partition_name..."
    fastboot erase "$partition_name"
    # echo "fastboot erase "$partition_name"" # testing purposes

    if [ $? -ne 0 ]; then
      echo "Failed to erase $partition_name."
      # exit 1
    fi
  done

  if [ -n "$ACTIVE_PARTITION" ]; then
    echo "All partitions on slot $ACTIVE_PARTITION erased successfully"
  else
    echo "All partitions on the active slot have been erased successfully"
  fi
}

# Function to flash a partition
flash_image() {
  local partition=$1
  local image=$2

  echo "Flashing ${partition} with ${image}..."
  fastboot flash $partition $image
  # echo "fastboot flash $partition $image" # testing purposes

  # Check if the flash command was successful
  if [ $? -ne 0 ]; then
    echo "ERROR: Flashing ${partition} failed!"
    failed_files+=("$image") # Add failed file to the failed array
  else
    echo "${partition} flashed successfully!"
  fi

  echo "" # Spacer
}

# Function to flash a partition and handle failures
flash_fastbootd_partitions() {
  enter_fastbootd_mode
  if [ $? -eq 0 ]; then
    echo "Device is not in fastbootd mode. Exiting."
    exit 1
  fi

  echo "Begin flashing dynamic partitions..."
  echo "" # Spacer

  failed_files=()
  for img in "${img_files[@]}"; do
    partition=$(basename "$img" .img) # Get partition name from filename
    active_suffix=$ACTIVE_PARTITION

    # Flash the partition
    flash_image "${partition}${active_suffix}" $img
  done
}

# Function to reboot into bootloader mode and finish flashing files
flash_bootloader_partitions() {
  if [ ${#failed_files[@]} -gt 0 ]; then
    enter_bootloader_mode
    if [ $? -eq 0 ]; then
      echo "Device is not in bootloader mode. Exiting."
      exit 1
    fi

    echo "Flashing system partitions..."
    echo "" # Spacer

    for failed_file in "${failed_files[@]}"; do
      partition=$(basename "$failed_file" .img) # Get partition name from filename
      flash_image $partition $failed_file
    done

    if [ ${#failed_files[@]} -gt 0 ]; then
      echo "Some files failed to flash after retrying. Logging to flash_failures.txt"
      echo "Failed to flash the following files:" >flash_failures.txt
      for failed_file in "${failed_files[@]}"; do
        echo "$failed_file" >>flash_failures.txt
      done
      echo "Please check flash_failures.txt for the failed files."
    else
      echo "All failed flashes succeeded after retry."
    fi
  else
    echo "No files to flash in fastbootd. Returning to the Flashing Menu"
  fi
}

# Main menu
while true; do
  echo "Flashing Menu"
  echo "-----------"
  echo "1. Enter fastbootd mode"
  echo "2. Enter bootloader mode"
  echo "3. Find device's active slot"
  echo "4. Select an active slot"
  if [ -n "$ACTIVE_PARTITION" ]; then
    echo "5. Erase slot $ACTIVE_PARTITION partitions"
  else
    echo "5. Erase active partitions"
  fi
  echo "6. Begin flashing in fastbootd mode (1/2)"
  echo "7. Finish flashing in bootloader mode (2/2)"
  echo "8. Reboot to device's OS"
  echo "9. Exit"
  read -p "Enter your choice: " choice
  clear

  case $choice in
  1) enter_fastbootd_mode ;;
  2) enter_bootloader_mode ;;
  3) get_active_partition ;;
  4) select_active_partition ;;
  5) erase_active_partition ;;
  6) flash_fastbootd_partitions ;;
  7) flash_bootloader_partitions ;;
  8) echo "fastboot reboot" ;;
  9) exit 0 ;;
  *) echo "Invalid choice. Please try again." ;;
  esac

  echo "" # Spacer
done
