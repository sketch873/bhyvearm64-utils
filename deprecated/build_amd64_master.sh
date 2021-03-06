#!/usr/bin/env bash
#-
# Copyright (c) 2015 Ruslan Bukin <br@bsdpad.com>
# All rights reserved.
#
# This software was developed by the University of Cambridge Computer
# Laboratory as part of the CTSRD Project, with support from the UK Higher
# Education Innovation Fund (HEIF).
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

log() {
	echo "$1"	| tee -a ${LOGFILE}
}

exit_on_failure() {
	exitcode=$?
	log "Error: $1 failed in ${SRC}"
	exit $exitcode
}

export TARGET=amd64
export TARGET_ARCH=amd64

#
# Predefined path to workspace
#
export WORKSPACE=$(realpath $HOME)/arm64-workspace/
export MAKEOBJDIRPREFIX=$WORKSPACE/amd64_obj/
export ROOTFS=$WORKSPACE/amd64_rootfs/
export OBJDIR=$MAKEOBJDIRPREFIX/$WORKSPACE/freebsd/amd64.amd64
export EFI_IMG=$OBJDIR/stand/efi/boot1/boot1.efi
export ROOTFS_IMG=$ROOTFS/rootfs.img

#
# Build from scratch if a specific build stage is not specified
#
BUILD_STAGE="${BUILD_STAGE:-0}"

#
# Truncate the log file to zero.
#
LOGFILE=$(realpath $HOME)/log
>${LOGFILE}

log ""
log "WORKSPACE=${WORKSPACE}"
log "MAKEOBJDIRPREFIX=${MAKEOBJDIRPREFIX}"
log "OBJDIR=${OBJDIR}"
log "ROOTFS=${ROOTFS}"
log "EFI_IMG=${EFI_IMG}"
log "ROOTFS_IMG=${ROOTFS_IMG}"
log ""

log ""
log "Build stage: ${BUILD_STAGE}"
log "Log file: ${LOGFILE}"
log ""

#
# Sanity checks
#
if [ "$USER" == "root" ]; then
	echo "Error: Can't run under root"	| tee -a ${LOGFILE}
	exit 1
fi

if [ "$(uname -s)" != "FreeBSD" ]; then
	echo "Error: Can run on FreeBSD only"	| tee -a ${LOGFILE}
	exit 1
fi

#
# Get path to SRC tree
#
if [ -z "$1" ]; then
	SRC=${WORKSPACE}/freebsd/
	log "Sources set to: ${SRC}"
else
	export SRC=$(realpath $1)
fi

if [ ! -d "${SRC}" ]; then
	log "Error: Provided path (${SRC}) is not a directory"
	exit 1
fi

export MAKESYSPATH=$SRC/share/mk
if [ ! -d "$MAKESYSPATH" ]; then
	log "Error: Can't find svn src tree"
	exit 1
fi

#
# Create dirs
#
mkdir -p $ROOTFS $MAKEOBJDIRPREFIX

#
# Clean first
#
if [ -n "${FULL_CLEAN}" ] && [ ${BUILD_STAGE} -eq 0 ]; then
	log "Doing cleandir"
	cd $SRC && \
		make cleandir && \
		make cleandir
	rm -rf $MAKEOBJDIRPREFIX
	mkdir $MAKEOBJDIRPREFIX
	DNO_CLEAN=""
else
	DNO_CLEAN="-DNO_CLEAN"
fi

#
# Number of CPU for parallel build
#
export NCPU=$(sysctl -n hw.ncpu)

#
# Build FreeBSD
#
cd $SRC
if [ ${BUILD_STAGE} -eq 0 ]; then
	log "Building world"
	make -j $NCPU TARGET=$TARGET TARGET_ARCH=$TARGET_ARCH -DWITHOUT_TESTS -DELF_VERBOSE ${DNO_CLEAN} buildworld | tee -a ${LOGFILE}
	if [ ${PIPESTATUS} -ne 0 ]; then
		exit_on_failure "buildworld"
	fi
fi

#
# Build the host kernel
#
if [ -z "${NO_KERNEL}" ]; then
	if [ ${BUILD_STAGE} -le 1 ] || [ ${BUILD_STAGE} -eq 999 ]; then
		log "Building host kernel"
		make -j $NCPU -DELF_VERBOSE buildkernel KERNCONF=GENERIC | tee -a ${LOGFILE}
		if [ ${PIPESTATUS} -ne 0 ]; then
			exit_on_failure "buildkernel"
		fi
	fi
fi

if [ -z "${NO_SYNC}" ]; then

	# Install FreeBSD
	if [ ${BUILD_STAGE} -le 2 ]; then
		make -DNO_ROOT -DWITHOUT_TESTS DESTDIR=$ROOTFS installworld | \
			tee -a ${LOGFILE}
		if [ ${PIPESTATUS} -ne 0 ]; then
			exit_on_failure "installworld"
		fi
	fi
	if [ ${BUILD_STAGE} -le 3 ]; then
		make -DNO_ROOT -DWITHOUT_TESTS DESTDIR=$ROOTFS distribution | \
			tee -a ${LOGFILE}
		if [ ${PIPESTATUS} -ne 0 ]; then
			exit_on_failure "distribution"
		fi
	fi

	make -DNO_ROOT -DWITHOUT_TESTS DESTDIR=$ROOTFS installkernel KERNCONF=GENERIC | \
		tee -a ${LOGFILE}
	if [ ${PIPESTATUS} -ne 0 ]; then
		exit_on_failure "installkernel"
	fi

	# Remove all traces of make install{world, kernel} and make distribution
	# ignoring -DNO_ROOT
	sed -i '' -E 's/usr\/home\/alex\/arm64-workspace\/\/amd64_rootfs//' $ROOTFS/METALOG | \
		tee -a ${LOGFILE}

	# Setup rootfs.
	echo '/dev/vtbd0s2 / ufs rw,noatime 1 1' > $ROOTFS/etc/fstab | \
		tee -a ${LOGFILE}
	echo './etc/fstab type=file uname=root gname=wheel mode=644' >> $ROOTFS/METALOG | \
		tee -a ${LOGFILE}

	# time= workaround
	sed -i '' -E 's/(time=[0-9]*)\.[0-9]*/\1.0/' $ROOTFS/METALOG | \
		tee -a ${LOGFILE}

	rm -rf ${ROOTFS_IMG}
	cd ${ROOTFS} && /usr/sbin/makefs -D ${ROOTFS_IMG} METALOG \
		2> ${WORKSPACE}/makefs_errors.log | tee -a ${LOGFILE}
	if [ ${PIPESTATUS} -ne 0 ]; then
		exit_on_failure "/usr/sbin/makefs"
	fi

	rm -rf ${ROOTFS}/amd64.img
	/usr/bin/mkimg 	-f raw \
			-s gpt \
			-b /boot/pmbr \
			-p freebsd-boot:=/boot/gptboot \
			-p freebsd-ufs:=${ROOTFS_IMG} \
			-o ${ROOTFS}/amd64.img | tee -a ${LOGFILE}
	if [ ${PIPESTATUS} -ne 0 ]; then
		exit_on_failure "/usr/sbin/mkimg"
	fi

	echo "Disk image ready: ${ROOTFS_IMG}" | tee -a ${LOGFILE}

	# Copy the disk to the host.
	if [ -z "${RSYNC_TARGET}" ]; then
		RSYNC_TARGET=host:/home/alex/data/freebsd/img
	fi

	rsync -arPhh ${ROOTFS_IMG} ${RSYNC_TARGET}/amd64.img --checksum | \
		tee -a ${LOGFILE}
	exitcode="${PIPESTATUS}"
	if [ "$exitcode" = "0" ]; then
		log "Disk image synced to host: ${RSYNC_TARGET}/amd64.img"
	else
		log "Error: cannot sync disk image to ${RSYNC_TARGET}/amd64.img"
		exit $exitcode
	fi
fi

log "$(date)"
