#!/bin/sh
set -eu

printf 'Reloading Core Audio driver hosts. Active audio sessions may be interrupted.\n'

printf 'Stopping Core Audio driver service helper if it is running...\n'
sudo pkill -TERM -f 'com.apple.audio.Core-Audio-Driver-Service.helper' 2>/dev/null || true
sudo pkill -TERM -f 'Core-Audio-Driver-Service.helper' 2>/dev/null || true

printf 'Stopping coreaudiod...\n'
sudo killall coreaudiod

printf 'Core Audio reload requested. Reopen audio clients, then refresh MCA.\n'
