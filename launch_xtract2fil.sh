#!/bin/bash

usage(){
    echo "This script launches xtract2fil on given raw files or directories containing raw files."
    echo "The default behaviour is intended for the directory structure of SPOTLIGHT's ParamRudra server."
    echo ""
    echo "Usage: $0 [OPTIONS] POSITIONAL_ARGS"
    echo ""
    echo "Options:"
    echo "      -f FBIN                     Frequency binning factor (default: 1)"
    echo "      -t TBIN                     Time binning factor (default: 1)"
    echo "      -j NJOBS                    Number of parallel jobs (default: 16)"
    echo "      -n NBEAMS                   Number of beams (default: 10)"
    echo "      -x OFFSET                   Offset value (default: 0)"
    echo "      -d DUAL                     Dual mode of xtract2fil (true/false, default: true)"
    echo "                                  If true, FBIN defaults to 4 and TBIN to 10."
    echo "      -o OUTPUT_DIR               Output directory (default: grand parent of raw files)"
    echo "      -s SCAN                     Scan name (default: derived from raw files)"
    echo "      -h                          Show help message and exit"
    echo ""
    echo "Positional arguments:"
    echo "      FNAME.raw.{0..15}           Input raw files"
    echo "OR"
    echo "      OBS_DIR1 [ ... ]           Input directories containing raw files"
}

sanity_checks_for_files(){
    for f in "${file_list[@]}"; do
        if [[ ! -e "$f" ]]; then
            echo "Warning: file not found: $f"
        fi
    done
}

sanity_checks_for_dirs(){
    for DIR in "${DIR_LIST[@]}"; do
        if [[ ! -d "$DIR" ]]; then
            echo "Warning: directory not found: $DIR"
            DIR_LIST=("${DIR_LIST[@]/$DIR}")    # remove from list
            continue
        fi
        raw_files=("$DIR"/*.raw.*)
        if (( ${#raw_files[@]} == 0 )); then
            echo "Warning: no raw files found in directory: $DIR"
            DIR_LIST=("${DIR_LIST[@]/$DIR}")    # remove from list
            continue
        fi
    done
}

read_ahdr_file(){
    if [[ -z "$AHDR_FILE" || ! -f "$AHDR_FILE" ]]; then
        echo "Error: AHDR file not found: $AHDR_FILE"
        return 1
    fi

    # Validate presence of Date and IST Time lines
    if ! grep -q '^Date[[:space:]]*=' "$AHDR_FILE"; then
        echo "Error: 'Date' line missing in AHDR file: $AHDR_FILE"
        echo "Help: Raw files may be corrupted or empty."
        return 1
    fi
    if ! grep -q '^IST Time[[:space:]]*=' "$AHDR_FILE"; then
        echo "Error: 'IST Time' line missing in AHDR file: $AHDR_FILE"
        echo "Help: Raw files may be corrupted or empty."
        return 1
    fi

    nbeams_per_host=$(sed -n 's/^Total No\. of Beams\/host.*= *//p' "$AHDR_FILE" | head -n1)
    if [[ -z "$nbeams_per_host" ]]; then
        echo "Error: Failed to parse 'Total No. of Beams/host' from AHDR file: $AHDR_FILE"
        return 1
    else
        echo "Total No. of Beams/host = $nbeams_per_host"
    fi

    if [[ $dual == true ]]; then
        dual_flag="--dual"
        if [[ $fbin -eq 1 && $tbin -eq 1 ]]; then
            # Extract values from AHDR file and determine default fbin and tbin.
            channels=$(sed -n 's/^Channels.*= *//p' "$AHDR_FILE" | head -n1)
            sampling_time_usec=$(sed -n 's/^Sampling time.*= *//p' "$AHDR_FILE" | head -n1)

            # Basic validations
            if [[ -z "$channels" || -z "$sampling_time_usec" ]]; then
                echo "Error: Failed to parse required AHDR fields from: $AHDR_FILE"
                echo "Channels: '${channels}', Sampling time (uSec): '${sampling_time_usec}'"
                return 1
            else
                echo "Channels: $channels, Sampling Time (uSec): $sampling_time_usec"
            fi

            if (( channels > dwnsmp_channels )); then
                fbin=$((dwnsmp_channels / channels))
            else
                fbin=1
            fi
            if (( $(echo "$sampling_time_usec < $dwnsmp_tsamp" | bc -l) )); then
                tbin=$(echo "$dwnsmp_tsamp / $sampling_time_usec" | bc -l)
                tbin=${tbin%.*}  # floor to integer
            else
                tbin=1
            fi
        fi
    else
        dual_flag="--no-dual"
    fi
}

xtract_N_chk(){
    echo "Starting xtract2fil for scan: $scan"
    echo "Output directory: $output_dir"
    echo "Frequency binning factor: $fbin"
    echo "Time binning factor: $tbin"

    xtract2fil \
        --fbin "$fbin" \
        --tbin "$tbin" \
        --njobs "$njobs" \
        --nbeams "$nbeams_per_host" \
        --offset "$offset" \
        $dual_flag \
        --output "$output_dir" \
        --scan "$scan" \
        "${file_list[@]}"

    EXIT_CODE=$?
    if [[ $EXIT_CODE -ne 0 ]]; then
        echo "xtract2fil failed with exit code: $EXIT_CODE"
        exit $EXIT_CODE
    else
        echo "xtract2fil completed successfully"
        rm "${file_list[@]}"

        if [[ $dual == true ]]; then
            for f in "${ahdr_list[@]}"; do
                cp "$f" "$output_dir/FilData/$scan/"
                cp "$f" "$output_dir/FilData_dwnsmp/$scan/"
            done
        else
            for f in "${ahdr_list[@]}"; do
                cp "$f" "$output_dir"
            done
        fi
    fi
}

main(){
    # Default parameters
    fbin=1
    tbin=1
    njobs=16
    nbeams_per_host=10
    offset=0
    dual=true
    output_dir=''
    scan=''
    inp_list=()
    MODE='' # 'files' or 'dirs'
    dwnsmp_channels=1024 # default channels after downsampling
    dwnsmp_tsamp=13107.2 # default sampling time after downsampling (in microseconds)

    while getopts "f:t:j:n:x:d:o:s:h" opt; do
        case $opt in
            f) fbin=$OPTARG ;;
            t) tbin=$OPTARG ;;
            j) njobs=$OPTARG ;;
            n) nbeams_per_host=$OPTARG ;;
            x) offset=$OPTARG ;;
            d) dual=$OPTARG ;;
            o) output_dir=$OPTARG ;;
            s) scan=$OPTARG ;;
            h) usage; exit 0 ;;
            *) echo "Invalid option: -$OPTARG"; usage; exit 1 ;;
        esac
    done

    # Capture positional arguments (filenames) after options
    shift $((OPTIND-1))
    if (( $# == 0 )); then
        echo "Error: no input files or directories provided as positional arguments"
        usage
        exit 1
    fi

    inp_list=("$@")
    # Expand inp_list to absolute paths
    for i in "${!inp_list[@]}"; do
        inp_list[$i]=$(realpath "${inp_list[$i]}")
    done

    # Determine mode based on the first input argument
    if [[ -d "${inp_list[0]}" ]]; then
        MODE='dirs'
        DIR_LIST=("${inp_list[@]}")

        if [[ -z "$output_dir" ]]; then
            DATA_DIR=$(dirname $(dirname "${DIR_LIST[0]}"))
        else
            DATA_DIR=$output_dir
        fi
    else
        MODE='files'
        file_list=("${inp_list[@]}")

        if [[ -z "$scan" ]]; then
            scan=$(basename --suffix .raw.0 "${inp_list[0]}")
        fi

        if [[ -z "$output_dir" ]]; then
            output_dir=$(dirname $(dirname "${file_list[0]}"))
            if [[ $dual == false ]]; then
                if [[ $fbin -eq 1 && $tbin -eq 1 ]]; then
                    output_dir="${output_dir}/FilData/$scan"
                else
                    output_dir="${output_dir}/FilData_dwnsmp/$scan"
                fi
            fi
        fi
    fi

    sanity_checks_for_${MODE}

    source "/lustre_archive/apps/tdsoft/env.sh"

    if [[ $MODE == 'dirs' ]]; then
        for DIR in "${DIR_LIST[@]}"; do
            OBS_NAME=$(basename $(dirname "${DIR}"))

            # Determine output directory for this observation.
            if [[ $dual == true ]]; then
                output_dir="${DATA_DIR}/$OBS_NAME"
            else
                if [[ $fbin -eq 1 && $tbin -eq 1 ]]; then
                    output_dir="${DATA_DIR}/${OBS_NAME}/FilData"
                else
                    output_dir="${DATA_DIR}/${OBS_NAME}/FilData_dwnsmp"
                fi
            fi

            # Start processing each scan in the directory.
            for scan in "$DIR"/*.raw.0; do
                scan=$(basename --suffix .raw.0 "$scan")
                
                file_list=("$DIR"/$scan.raw.*)                
                filtered=()
                ahdr_list=()
                for f in "${file_list[@]}"; do
                    if [[ $f == *.raw.*.ahdr ]]; then
                        ahdr_list+=("$f")
                        continue
                    fi
                    filtered+=("$f")
                done
                file_list=("${filtered[@]}")

                AHDR_FILE="${ahdr_list[0]}"
                read_ahdr_file
                if [[ $? -ne 0 ]]; then
                    echo "Skipping scan $scan due to AHDR file error(s)."
                    echo "-------------------------------- Invalid data for scan $scan --------------------------------"
                    continue
                fi

                xtract_N_chk
                echo "-------------------------------- xtract2fil for scan $scan done --------------------------------"
            done
        done
    else
        AHDR_FILE="${file_list[0]}.ahdr"
        read_ahdr_file
        if [[ $? -ne 0 ]]; then
            echo "Cannot process $scan due to AHDR file error(s)."
            continue
        fi

        xtract_N_chk
    fi
}

main "$@"