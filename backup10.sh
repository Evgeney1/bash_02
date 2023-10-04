#!/usr/bin/env bash

set -Eeuo pipefail
logg() {
    exec > >(tee >(logger -p local0.notice -t "$(basename "$0") in ${1}"))
    exec 2> >(tee >&2 >(logger -p local0.error -t "$(basename "$0") in ${1}"))
}

#font settings for usage message in exit_abnormal()
BOLD=$(tput bold)
NORMAL=$(tput sgr0)

exit_abnormal() {
    echo "Usage:
  $0 ${BOLD}-c${NORMAL} [JSON CONFIG FILE]
  $0    [SOURCE DIRECTORY] [DISTINATION ARCHIVE FILE]" >&2
    echo "Note: only one instance of the script can run at time" >&2
    exit 1
}

#region parse
logg "parsing"
while getopts ":c:" options; do
    case "${options}" in
    c)
        if [ -f "$OPTARG" ]; then
            CONFIGFILENAME=${OPTARG}
            if ! jq -e . >/dev/null 2>&1 <<<"$(cat "${CONFIGFILENAME}")"; then
                echo "Error: could not parse json file" >&2
                exit_abnormal
            else
                SOURCEDIR=$(jq -r '.sourcedir' "${CONFIGFILENAME}")
                DISTINATIONDIR=$(jq -r '.distinationdir' "${CONFIGFILENAME}")
                ANNUALMARK=$(jq -r '.annualmark' "${CONFIGFILENAME}")
                MONTHLYMARK=$(jq -r '.monthlymark' "${CONFIGFILENAME}")
                WEEKLYMARK=$(jq -r '.weeklymark' "${CONFIGFILENAME}")
                DAILYSTORAGETIME=$(jq -r '.dailystoragetime' "${CONFIGFILENAME}")
                WEEKLYSTORAGETIME=$(jq -r '.weeklystoragetime' "${CONFIGFILENAME}")
                MONTHLYSTORAGETIME=$(jq -r '.monthlstorageytime' "${CONFIGFILENAME}")
                ANNUALSTORAGETIME=$(jq -r '.annualstoragetime' "${CONFIGFILENAME}")
            fi
        else
            echo "Error: config file not found." >&2
            exit_abnormal

        fi
        ;;
    :)
        echo "Error: \"-${OPTARG}\" requires an argument." >&2
        exit_abnormal
        ;;
    *)
        echo "Error: unknown option." >&2
        exit_abnormal
        ;;
    esac
done

#region check input args count

if [ $# -lt 2 ] || [ $# -gt 2 ]; then
    echo "Error, wrong options count". >&2
    exit_abnormal
fi
#endregion

#region assign default values, if option -c not assigned
if [ ! "$1" = "-c" ]; then
    SOURCEDIR="${1}"
    DISTINATIONDIR="${2}"
    ANNUALMARK="0310" #default: 3112
    MONTHLYMARK="03"  #default: 01
    WEEKLYMARK="2"    #default: 7
    DAILYSTORAGETIME="6"
    WEEKLYSTORAGETIME="28"
    MONTHLYSTORAGETIME="90"
    ANNUALSTORAGETIME="365"
fi
#endregion

#region check source directory existing and size
if [ -d "${SOURCEDIR}" ] || [ -f "${SOURCEDIR}" ]; then
    SIZE="$(du -h "${SOURCEDIR}" | cut -d $'\t' -f 1)"
    if [ "${SIZE}" = 0 ]; then
        echo "Error: directory or file \"${SOURCEDIR}\" is empty" >&2
        exit_abnormal
    fi
fi
#endregion
#endregion parse

#region tar check
command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 || {
    echo "Error: tar or gzip not found" >&2
    exit_abnormal
}
#endregion tar check

backup() {
    logg "${FUNCNAME[0]} function"
    local BACKUPTYPES=()
    if [[ "${ANNUALMARK}" == $(date +"%d%m") ]]; then
        BACKUPTYPES+=("annual")
    fi
    if [[ "${MONTHLYMARK}" == $(date +"%d") ]]; then
        BACKUPTYPES+=("monthly")
    fi
    if [[ "${WEEKLYMARK}" == $(date +"%u") ]]; then
        BACKUPTYPES+=("weekly")
    fi

    if [ ! -d "${DISTINATIONDIR}""/daily" ]; then
        mkdir -p "${DISTINATIONDIR}""/daily"
    fi
    local DAILYFILENAME
    DAILYFILENAME="$(date +"%Y-%m-%d-%H-%M-%S-daily.tar.gz")"
    if (! tar -czf "${DISTINATIONDIR}/daily/${DAILYFILENAME}" "${SOURCEDIR}"); then
        exit 1
    fi

    for TYPE in "${BACKUPTYPES[@]}"; do
        if [[ ! -d "${DISTINATIONDIR}/""${TYPE}" ]]; then
            mkdir -p "${DISTINATIONDIR}/""${TYPE}"
        fi
        ln "${DISTINATIONDIR}/daily/${DAILYFILENAME}" "${DISTINATIONDIR}/${TYPE}/${DAILYFILENAME/daily/$TYPE}"
    done
}

cleanup_backup_by_time() {
    logg "${FUNCNAME[0]} function"
    declare -A COPIESMTIME=([annual]=$ANNUALSTORAGETIME [monthly]=$MONTHLYSTORAGETIME
        [weekly]=$WEEKLYSTORAGETIME [daily]=$DAILYSTORAGETIME)

    for VAR in "${!COPIESMTIME[@]}"; do
        local MTIME="${COPIESMTIME[${VAR}]}"
        find "${DISTINATIONDIR}" -type f -name "*${VAR}*" -mtime +"${MTIME}" -delete
    done
}

cleanup_backup_by_count() {
    logg "${FUNCNAME[0]} function"
    declare -A COPIESCOUNT=([annual]=1 [monthly]=3 [weekly]=4 [daily]=6)
    local FILESCOUNT
    local TAILSIZE
    for VAR in "${!COPIESCOUNT[@]}"; do
        FILESCOUNT=$(find "${DISTINATIONDIR}" -type f -name "*${VAR}*" | wc -l)
        TAILSIZE="${COPIESCOUNT[${VAR}]}"
        ((TAILSIZE++))
        if ((FILESCOUNT > "${COPIESCOUNT[${VAR}]}")); then
            MOSTOLDFILE=$(find "${DISTINATIONDIR}" -type f -name "*${VAR}*" | tail -"${TAILSIZE}" | head -1)
            find "${DISTINATIONDIR}" -type f -name "*${VAR}*" ! -newer "${MOSTOLDFILE}" -delete
        fi
    done
}

LOCKFILENAME="backup.lock$(date +"%Y-%m-%d-%H-%M-%S")"
(
    flock -x -w 0 200 || exit_abnormal
    logg "main"
    if (backup); then
        echo "backup complete"
        if (cleanup_backup_by_time); then
            echo "cleanup complete"
        else
            echo "cleanup error" >&2
        fi
    else
        echo "backup error" >&2
    fi
) 200>"${HOME}/${LOCKFILENAME}backup.lock"
rm "${HOME}/${LOCKFILENAME}backup.lock"
