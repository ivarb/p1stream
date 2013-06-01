#!/bin/bash
set -e -x

# To get consistent builds, files generated by the original build system are
# also committed. This script executes the build system and copies those files
# to `generated/`.

# Running this script is only necessary when updating the dependency in the
# repository, and it's rather much dependant on the environment.

# Updating the dependency involves updating the submodule, running this script,
# and carefully reviewing submodule changes for things that need to be
# reflected in the project build settings.


# Gettext version we're targetting. Should match the submodule.
VERSION="0.18.2.1"


# Create scratch directory.
SCRATCH="`dirname $0`/../_scratch"
mkdir -p $SCRATCH
cd $SCRATCH

# Download the tarball.
BASENAME="gettext-${VERSION}"
TARBALL="${BASENAME}.tar.gz"
if [ ! -e "${TARBALL}" ]; then
    wget "http://ftp.gnu.org/pub/gnu/gettext/${TARBALL}"
fi

# Unpack (and trash old scratch dir)
rm -fr "${BASENAME}"
tar -xzf "${TARBALL}"
cd "${BASENAME}/gettext-runtime"

# Run configure and make on specific files.
./configure \
    --enable-shared \
    --disable-static \
    --enable-relocatable \
    --disable-nls \
    --disable-c++ \
    --disable-java
make -C intl libintl.h libgnuintl.h

# Copy generated files.
OUT="../../../libintl/generated/gettext-runtime"
mkdir -p "${OUT}/intl/"
cp config.h "${OUT}/"
cp intl/libintl.h intl/libgnuintl.h "${OUT}/intl/"