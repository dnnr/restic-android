# restic-android

A Termux bash script for backing up your Android device with restic.

## Features
 * Automatically registers a periodic job (30 minutes interval) that only runs when the conditions
   are right (charging, battery not low, unmetered network)
 * Aborts an ongoing backup when disconnecting from charger or Wifi (conditions are checked every 15
   seconds)
 * Posts notifications for errors and while backup is ongoing

## Setup

 1. Install [Termux](https://f-droid.org/en/packages/com.termux/) and [Termux:API](https://f-droid.org/en/packages/com.termux.api/)
 2. Copy `restic-android.sh` into Termux home and make it executable
 3. Create custom `~/.config/restic-android/env` file based on `env.sample`
 4. Run `restic-android.sh` once to set up scheduled job
 5. Optional: Run termux-setup-storage to grant access to all shared storage
