#!/bin/bash
# Recorder stubs for the DuckyScript alert commands. Requires $REC set to a file.
: "${REC:?REC must point to a recorder file}"
ALERT()    { printf 'ALERT\t%s\n'    "$*" >> "$REC"; }
RINGTONE() { printf 'RINGTONE\t%s\n' "$*" >> "$REC"; }
VIBRATE()  { printf 'VIBRATE\t%s\n'  "$*" >> "$REC"; }
LED()      { printf 'LED\t%s\n'      "$*" >> "$REC"; }
LOG()      { printf 'LOG\t%s\n'      "$*" >> "$REC"; }
