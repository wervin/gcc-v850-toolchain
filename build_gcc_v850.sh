# exit if command failed.
set -o errexit
# exit if pipe failed.
set -o pipefail
# exit if variable not set.
set -o nounset

apt update -y
apt install build-essential mingw-w64 wget texinfo bison zip -y

BINUTILS_VERSION="2.45"
GCC_VERSION="10.2.0"
NEWLIB_VERSION="4.1.0"

BUILD="x86_64-linux-gnu"
LINUX_HOST="x86_64-linux-gnu"
TARGET="v850-elf"
BASE_PATH="/tmp/work"

SOURCE_PATH="${BASE_PATH}/source"
BUILD_LINUX_PATH="${BASE_PATH}/build/linux"
INSTALL_LINUX_PATH="${BASE_PATH}/install/v850-elf-gcc-linux-x64"
STAGE_PATH="${BASE_PATH}/stage"
export PATH="${INSTALL_LINUX_PATH}/bin:${PATH}"

mkdir -p ${SOURCE_PATH}
mkdir -p ${BUILD_LINUX_PATH}
mkdir -p ${INSTALL_LINUX_PATH}
mkdir -p ${STAGE_PATH}

# download tarballs in parallel
echo "Starting parallel downloads..."
DOWNLOAD_PIDS=""

if [ ! -e ${STAGE_PATH}/download_binutils ]
then
    wget -c -P ${SOURCE_PATH} http://ftpmirror.gnu.org/binutils/binutils-${BINUTILS_VERSION}.tar.gz &
    DOWNLOAD_PIDS="$DOWNLOAD_PIDS $!"
fi

if [ ! -e ${STAGE_PATH}/download_gcc ]
then
    wget -c -P ${SOURCE_PATH} http://ftpmirror.gnu.org/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.gz &
    DOWNLOAD_PIDS="$DOWNLOAD_PIDS $!"
fi

if [ ! -e ${STAGE_PATH}/download_newlib ]
then
    wget -c -P ${SOURCE_PATH} ftp://sourceware.org/pub/newlib/newlib-${NEWLIB_VERSION}.tar.gz &
    DOWNLOAD_PIDS="$DOWNLOAD_PIDS $!"
fi

# Wait for all downloads to complete
if [ -n "$DOWNLOAD_PIDS" ]; then
    echo "Waiting for downloads to complete..."
    for pid in $DOWNLOAD_PIDS; do
        wait $pid
    done
fi

# Mark downloads as complete
[ ! -e ${STAGE_PATH}/download_binutils ] && touch ${STAGE_PATH}/download_binutils
[ ! -e ${STAGE_PATH}/download_gcc ] && touch ${STAGE_PATH}/download_gcc
[ ! -e ${STAGE_PATH}/download_newlib ] && touch ${STAGE_PATH}/download_newlib

# extract tarballs
if [ ! -e ${STAGE_PATH}/extract_binutils ]
then
    tar -xvf ${SOURCE_PATH}/binutils-${BINUTILS_VERSION}.tar.gz -C ${SOURCE_PATH}
    touch ${STAGE_PATH}/extract_binutils
fi

if [ ! -e ${STAGE_PATH}/extract_gcc ]
then
    tar -xvf ${SOURCE_PATH}/gcc-${GCC_VERSION}.tar.gz -C ${SOURCE_PATH}
    touch ${STAGE_PATH}/extract_gcc
fi

if [ ! -e ${STAGE_PATH}/extract_newlib ]
then
    tar -xvf ${SOURCE_PATH}/newlib-${NEWLIB_VERSION}.tar.gz -C ${SOURCE_PATH}
    touch ${STAGE_PATH}/extract_newlib
fi

# download gcc prerequisites
cd ${SOURCE_PATH}/gcc-${GCC_VERSION}
./contrib/download_prerequisites

# build linux toolchain
if [ ! -e ${STAGE_PATH}/build_linux_binutils ]
then
    mkdir -p ${BUILD_LINUX_PATH}/binutils
    cd ${BUILD_LINUX_PATH}/binutils

    ${SOURCE_PATH}/binutils-${BINUTILS_VERSION}/configure \
        --build=${BUILD} \
        --host=${LINUX_HOST} \
        --target=${TARGET} \
        --prefix=${INSTALL_LINUX_PATH} \
        --disable-nls

    make -j$(nproc)
    make install-strip

    touch ${STAGE_PATH}/build_linux_binutils
fi

if [ ! -e ${STAGE_PATH}/build_linux_gcc_1st ]
then
    mkdir -p ${BUILD_LINUX_PATH}/gcc_1st
    cd ${BUILD_LINUX_PATH}/gcc_1st

    ${SOURCE_PATH}/gcc-${GCC_VERSION}/configure \
        --build=${BUILD} \
        --host=${LINUX_HOST} \
        --target=${TARGET} \
        --prefix=${INSTALL_LINUX_PATH} \
        --enable-languages=c \
        --without-headers \
        --with-newlib  \
        --with-gnu-as \
        --with-gnu-ld \
        --disable-threads \
        --disable-libssp \
        --disable-shared \
        --disable-nls

    make -j$(nproc) all-gcc
    make install-strip-gcc

    touch ${STAGE_PATH}/build_linux_gcc_1st
fi

if [ ! -e ${STAGE_PATH}/build_linux_newlib ]
then
    mkdir -p ${BUILD_LINUX_PATH}/newlib
    cd ${BUILD_LINUX_PATH}/newlib

    ${SOURCE_PATH}/newlib-${NEWLIB_VERSION}/configure \
        --build=${BUILD} \
        --host=${LINUX_HOST} \
        --target=${TARGET} \
        --prefix=${INSTALL_LINUX_PATH} \
        --enable-newlib-nano-malloc \
        --enable-newlib-nano-formatted-io \
        --enable-newlib-reent-small \
        --disable-nls

    make -j$(nproc) CFLAGS_FOR_TARGET="-fcommon -gdwarf-2 -fdata-sections -ffunction-sections -g -Os -D__rtems__"
    make install

    touch ${STAGE_PATH}/build_linux_newlib
fi

if [ ! -e ${STAGE_PATH}/build_linux_gcc_2nd ]
then
    mkdir -p ${BUILD_LINUX_PATH}/gcc_2nd
    cd ${BUILD_LINUX_PATH}/gcc_2nd

    ${SOURCE_PATH}/gcc-${GCC_VERSION}/configure \
        --build=${BUILD} \
        --host=${LINUX_HOST} \
        --target=${TARGET} \
        --prefix=${INSTALL_LINUX_PATH} \
        --enable-languages=c,c++ \
        --with-headers \
        --with-newlib  \
        --with-gnu-as \
        --with-gnu-ld \
        --disable-threads \
        --disable-libssp \
        --disable-shared \
        --disable-nls

    make -j$(nproc)
    make install-strip

    touch ${STAGE_PATH}/build_linux_gcc_2nd
fi

# Generate VERSION.txt with tool versions and build info
echo "V850 ELF GCC Toolchain" > ${INSTALL_LINUX_PATH}/VERSION.txt
echo "======================" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "Binutils: ${BINUTILS_VERSION}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "GCC: ${GCC_VERSION}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "Newlib: ${NEWLIB_VERSION}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "Build Date: $(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "Build Host: ${BUILD}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
echo "Target: ${TARGET}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
if [ -n "${CI_COMMIT_TAG:-}" ]; then
    echo "Release Tag: ${CI_COMMIT_TAG}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
fi
if [ -n "${CI_COMMIT_SHA:-}" ]; then
    echo "Commit: ${CI_COMMIT_SHA}" >> ${INSTALL_LINUX_PATH}/VERSION.txt
fi

# Create tar.xz archive
cd ${BASE_PATH}/install
tar -cJf v850-elf-gcc-linux-x64.tar.xz v850-elf-gcc-linux-x64