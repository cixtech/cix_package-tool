#!/usr/bin/env bash

#  Copyright 2024 Cix Technology Group Co., Ltd.
#  All Rights Reserved.
#
#  The following programs are the sole property of Cix Technology Group Co., Ltd.,
#  and contain its proprietary and confidential information.
#

# Description: build tf-a and tee, and package to cix flash all
# Author: Xinjun
# Date: 2025-10-20
# Revision: original v1.0
#

export GITHUB_USER="cixtech"

export  BOLD="\e[1m"
export  NORMAL="\e[0m"
export	RED="\e[31m"
export	GREEN="\e[32m"
export	YELLOW="\e[33m"
export  BLUE="\e[94m"
export  CYAN="\e[36m"

function cix_print_trace() {
    local -a lineno func file
    local len_lineno=0 len_func=0 len_file=0
    local i
    local callinfo
    for ((i=0; ; i++)) ; do
        callinfo="$(caller $((i+1)))" || break

        lineno+=( "${callinfo%% *}" )
        [[ ${#lineno[i]} -lt $len_lineno ]] || len_lineno=${#lineno[i]}
        callinfo="${callinfo#* }"

        func+=( "${callinfo%% *}" )
        [[ ${#func[i]} -lt $len_func ]] || len_func=${#func[i]}
        callinfo="${callinfo#* }"

        file+=( "$callinfo" )
        [[ ${#file[i]} -lt $len_file ]] || len_file=${#file[i]}
    done
    local -r depth="$i"

    local -r fmt_str="%-${len_func}s  %-${len_file}s  %-${len_lineno}s\n"
    printf "$BOLD$fmt_str$NORMAL" "func" "file" "line"
    for ((i=0; i<depth ; i++)) ; do
        printf "$fmt_str" "${func[i]}" "${file[i]}" "${lineno[i]}"
    done
}

function cix_handle_error () {
    local -r exit_code=$?
    {
        error_echo "$SELF terminated with a non-zero code ($exit_code)!"
        echo ""
        echo "call trace:"
        cix_print_trace
    } >&2
    exit 1
}

function die() {
    echo -e "$BOLD${RED}ERROR:$NORMAL$RED $*$NORMAL" >&2
    exit 1
}

function do_blankfile() {
	for ((i=0;i<$2;i++))
	do
		echo -e -n "\xFF" >> $1
	done
}

function do_build_tf_a() {
    cd "${PATH_TFA}"

    export CROSS_COMPILE="$CROSS_COMPILE"
    export BUILD_DIR="${PATH_OUT}/tf-a/sky1/${BUILD_MODE}"
    local DEBUG=0
    if [[ "${BUILD_MODE}" == "debug" ]]; then
        DEBUG=1
    fi

    echo "build SKY1 tf-a start (DEBUG=${DEBUG})"

    if [ -d "${PATH_OUT}/tf-a" ];then
        echo "clean tfa"
        rm -rf "${PATH_OUT}/tf-a"
    fi

    make -j$PARALLELISM PLAT=sky1 SPD=opteed \
        DEBUG=${DEBUG} \
        BUILD_BASE="${PATH_OUT}/tf-a" \
        CIX_BOARD=evb \
        SMP=1 \
        TRUSTED_BOARD_BOOT=1 \
        ENABLE_FEAT_HCX=1 \
        ARM_ROTPK_LOCATION=devel_rsa \
        ROT_KEY=plat/arm/board/common/rotpk/arm_rotprivk_rsa.pem \
        bl31

    echo "build SKY1 tf-a done"

    cp -f "${BUILD_DIR}/bl31.bin" "${PATH_OUT}/tf-a.bin"

    if [[ -e "${BUILD_DIR}/bl31/bl31.elf" ]]; then
        cp -f "${BUILD_DIR}/bl31/bl31.elf" "${PATH_OUT}/bl31.elf"
    fi

}

function do_build_tee() {
    echo -e "BUILD TEE Started."
    cd "${PATH_TEE}"
    make clean
    if [[ -e "${PATH_TEE}/out" ]]; then
        rm -rf "${PATH_TEE}/out"
    fi
    if [[ -e "${PATH_TEE}/tee.bin" ]]; then
        rm -rf "${PATH_TEE}/tee.bin"
    fi

    echo "build SKY1 tee start"

    export PLATFORM_FLAVOR=sky1
    if [ -e "${PATH_PACKAGE_TOOL}/Firmwares/BL32_AP_EFI_STMM.fd" ]; then
	    export CFG_STMM_PATH="${PATH_PACKAGE_TOOL}/Firmwares/BL32_AP_EFI_STMM.fd"
    fi

    make -j${PARALLELISM} TA_SIGN_KEY=${PATH_PACKAGE_TOOL}/Keys/oem_privatekey.pem \
        ARCH=arm CROSS_COMPILE64="${CROSS_COMPILE}" CFG_ARM64_core=y CFG_USER_TA_TARGETS=ta_arm64 all

    cp -f "${PATH_TEE}/out/arm-plat-cix/core/tee-raw.bin" "${PATH_OUT}/tee.bin"

    echo "build SKY1 tee done"
}

function do_package_all() {
    local build_key_type="pr"
    local path_out_temp="${PATH_OUT}/${build_key_type}"
    local flash_all_file_name="cix_flash_all"

    if [[ ! -e "${PATH_OUT}/tf-a.bin" ]]; then
        die "${RED}please generate tf-a.bin${NORMAL}"
    fi
    if [[ ! -e "${PATH_OUT}/tee.bin" ]]; then
        die "${RED}please generate tee.bin${NORMAL}"
    fi
    
    if [[ -e "${path_out_temp}" ]]; then
        rm -rf "${path_out_temp}"
    fi
    mkdir -p ${path_out_temp}

    cp -rf ${PATH_PACKAGE_TOOL}/Firmwares ${path_out_temp}/
    cp -rf ${PATH_PACKAGE_TOOL}/certs ${path_out_temp}/
    cp -rf ${PATH_PACKAGE_TOOL}/Keys ${path_out_temp}/
    cp -f ${PATH_PACKAGE_TOOL}/cert_create_rsa ${path_out_temp}/

    if [[ ! -e "${path_out_temp}/Firmwares/dummy.bin" ]]; then
        do_blankfile "${path_out_temp}/Firmwares/dummy.bin" 8192
    fi

    if [ "$(uname -m)" = "aarch64" ]; then
      cp -f ${PATH_PACKAGE_TOOL}/AARCH64/cert_uefi_create_rsa ${path_out_temp}/
      cp -f ${PATH_PACKAGE_TOOL}/AARCH64/cix_package_tool ${path_out_temp}/
      cp -f ${PATH_PACKAGE_TOOL}/AARCH64/fiptool ${path_out_temp}/
    else
      cp -f ${PATH_PACKAGE_TOOL}/X86_64/cert_uefi_create_rsa ${path_out_temp}/
      cp -f ${PATH_PACKAGE_TOOL}/X86_64/cix_package_tool ${path_out_temp}/
      cp -f ${PATH_PACKAGE_TOOL}/X86_64/fiptool ${path_out_temp}/
    fi

    cp ${PATH_PACKAGE_TOOL}/spi_flash_config_all.json ${path_out_temp}

    echo "build bootloader2 (${build_key_type})"
    cd "${path_out_temp}"
	./cert_create_rsa --key-alg rsa --key-size 3072 \
        --hash-alg sha256 --tfw-nvctr 31 \
        --rot-key ${path_out_temp}/Keys/oem_privatekey.pem \
        --trusted-world-key ${path_out_temp}/Keys/oem_privatekey.pem \
        --soc-fw-key ${path_out_temp}/Keys/oem_privatekey.pem \
        --tos-fw-key ${path_out_temp}/Keys/oem_privatekey.pem \
        --trusted-key-cert ${path_out_temp}/certs/trusted_key.crt \
        --soc-fw-key-cert ${path_out_temp}/certs/bl31_fw_key.crt \
        --tos-fw-key-cert ${path_out_temp}/certs/tos_fw_key.crt \
        --soc-fw-cert ${path_out_temp}/certs/bl31_fw_content.crt \
        --tos-fw-cert ${path_out_temp}/certs/tos_fw_cert.crt \
        --soc-fw ${PATH_OUT}/tf-a.bin \
        --tos-fw ${PATH_OUT}/tee.bin

	./fiptool create \
        --soc-fw ${PATH_OUT}/tf-a.bin \
        --tos-fw ${PATH_OUT}/tee.bin \
        --trusted-key-cert ${path_out_temp}/certs/trusted_key.crt \
        --soc-fw-key-cert ${path_out_temp}/certs/bl31_fw_key.crt \
        --tos-fw-key-cert ${path_out_temp}/certs/tos_fw_key.crt \
        --soc-fw-cert ${path_out_temp}/certs/bl31_fw_content.crt \
        --tos-fw-cert ${path_out_temp}/certs/tos_fw_cert.crt \
        ${path_out_temp}/Firmwares/bootloader2.img

    ./cert_uefi_create_rsa --key-alg rsa --key-size 3072 --hash-alg sha256 -p --ntfw-nvctr 223 \
        --nt-fw-cert ${path_out_temp}/certs/nt_fw_cert.crt \
        --nt-fw-key-cert ${path_out_temp}/certs/nt_fw_key.crt \
        --nt-fw-key ${path_out_temp}/Keys/oem_privatekey.pem \
        --non-trusted-world-key ${path_out_temp}/Keys/oem_privatekey.pem \
        --nt-fw ${path_out_temp}/Firmwares/SKY1_BL33_UEFI.fd

    ./fiptool create \
        --trusted-key-cert ${path_out_temp}/certs/trusted_key_no.crt \
        --nt-fw-key-cert ${path_out_temp}/certs/nt_fw_key.crt \
        --nt-fw-cert ${path_out_temp}/certs/nt_fw_cert.crt \
        --nt-fw ${path_out_temp}/Firmwares/SKY1_BL33_UEFI.fd \
        ${path_out_temp}/Firmwares/bootloader3.img

    if [[ ! -e "${path_out_temp}/Firmwares/bootloader2.img" ]]; then
        die "ERROR: no file ${path_out_temp}/Firmwares/bootloader2.img"
    fi

    if [[ ! -e "${path_out_temp}/Firmwares/bootloader3.img" ]]; then
        die "ERROR: no file ${path_out_temp}/Firmwares/bootloader3.img"
    fi

    echo "generate spi flash image (${build_key_type})"

    cd "${path_out_temp}"

	 echo "./cix_package_tool -c spi_flash_config_all.json -o ${flash_all_file_name}.bin"
    ./cix_package_tool -c spi_flash_config_all.json -o ${flash_all_file_name}.bin
    cp ${flash_all_file_name}.bin ${PATH_OUT}/${flash_all_file_name}.bin

    echo -e "${GREEN}Generate ${PATH_OUT}/${flash_all_file_name}.bin successful!${NORMAL}"
}

function do_help() {
    echo -e "${BOLD}Usage:"
    echo -e "    $SELF ${CYAN}<options>${NORMAL}"
    echo

    cat <<- EOF
    <options>:
        -h, --help:               show the help info
        -r, --res:                fetch the source codes
        -b, --build:              build and package default if no param
                                  $SELF -b       # build tf-a and tee, and package them
                                  $SELF -b tf_a  # build tf-a only
                                  $SELF -b tee   # build tee only
        -t, --toolchain:          the toolchain path and CROSS_COMPILE value will be "<toolchain path>/bin/aarch64-none-elf-"
EOF
}

function do_fetch_res() {
    if [[ ! -e "${PATH_ROOT}/bsp" ]]; then
        mkdir -p "${PATH_ROOT}/bsp"
    fi
    if [[ ! -e "${PATH_TEE}" ]] || [[ ! -e "${PATH_TEE}/.git" ]]; then
        git clone https://github.com/${GITHUB_USER}/cix_opensource__tee__op-tee.git -b cix_p1_k6.6_2025q3_tfa_open_dev ${PATH_TEE}
    fi
    if [[ ! -e "${PATH_TFA}" ]] || [[ ! -e "${PATH_TFA}/.git" ]]; then
        git clone https://github.com/${GITHUB_USER}/cix_opensource__arm-trusted-firmware.git -b cix_p1_k6.6_2025q3_tfa_open_dev ${PATH_TFA}
    fi
}

function do_build() {
    if [[ ! -e "$(dirname ${CROSS_COMPILE})" ]]; then
        die "${RED}$(dirname ${CROSS_COMPILE}) does not exist${NORMAL}"
    fi
    if [[ ! -e "${PATH_TFA}" ]]; then
        die "${RED}${PATH_TFA} does not exist${NORMAL}"
    fi
    if [[ ! -e "${PATH_TEE}" ]]; then
        die "${RED}${PATH_TEE} does not exist${NORMAL}"
    fi
    if [[ ! -e "${PATH_PACKAGE_TOOL}" ]]; then
        die "${RED}${PATH_PACKAGE_TOOL} does not exist${NORMAL}"
    fi

    if [[ ! -e "${PATH_OUT}" ]]; then
        mkdir -p "${PATH_OUT}"
    fi

    echo "******************ENV VALUE***********************"
    echo -e "PATH_WORKSPACE:                  ${YELLOW}${PATH_WORKSPACE}${NORMAL}"
    echo -e "PATH_ROOT:                       ${YELLOW}${PATH_ROOT}${NORMAL}"
    echo -e "CROSS_COMPILE:                   ${YELLOW}${CROSS_COMPILE}${NORMAL}"
    echo -e "PATH_TFA:                        ${YELLOW}${PATH_TFA}${NORMAL}"
    echo -e "PATH_TEE:                        ${YELLOW}${PATH_TEE}${NORMAL}"
    echo -e "PATH_PACKAGE_TOOL:               ${YELLOW}${PATH_PACKAGE_TOOL}${NORMAL}"
    echo -e "PATH_OUT:                        ${YELLOW}${PATH_OUT}${NORMAL}"
    echo "**************************************************"

    do_build_tf_a
    do_build_tee

    do_package_all
}

trap cix_handle_error ERR

PARALLELISM=`grep -c ^processor /proc/cpuinfo 2>/dev/null`
PATH_ORIGINAL=$(pwd)
export SELF=$0
export PATH_WORKSPACE="$(realpath --no-symlinks "$(dirname "${BASH_SOURCE[0]}")")"

export PATH_ROOT="$(realpath --no-symlinks "${PATH_WORKSPACE}/..")"
export PLATFORM=cix
export BUILD_MODE=release
export CROSS_COMPILE=${CROSS_COMPILE:-${PATH_ROOT}/tools/gcc/gcc-arm-10.2-2020.11-x86_64-aarch64-none-elf/bin/aarch64-none-elf-}

export PATH_TFA=${PATH_TFA:-${PATH_ROOT}/bsp/tf-a}
export PATH_TEE=${PATH_TEE:-${PATH_ROOT}/bsp/tee}

export PATH_PACKAGE_TOOL=${PATH_PACKAGE_TOOL:-${PATH_WORKSPACE}}
export PATH_OUT="${PATH_ROOT}/output"

CMD="build"
PARAM=""
while [[ $# -gt 0 ]]; do
    case $1 in
    ("-h" | "--help")
        CMD="help"
        do_help
        exit 0
        ;;
    ("-r" | "--res")
        CMD="resource"
        ;;
    ("-b" | "--build")
        CMD="build"
        if [[ $# -gt 1 ]] && [[ "$2" != "-"* ]]; then
            PARAM=$2
            shift
        fi
        ;;
    ("-t" | "--toolchain")
        shift
        export CROSS_COMPILE=$(realpath --no-symlinks $1)/bin/aarch64-none-elf-
        ;;
    (*)
        echo -e "${RED}option $1 is not supported. ${GREEN}line: ${LINENO}${NORMAL}"
        do_help
        exit 0
        ;;
    esac
    shift
done

case "${CMD}" in
    ("help")
        do_help
        ;;
    ("resource")
        do_fetch_res
        ;;
    ("build")
        if [[ ${#PARAM} -gt 1 ]]; then
            do_build_${PARAM} || true
        else
            do_build
        fi
        ;;
esac

cd "${PATH_ORIGINAL}"
