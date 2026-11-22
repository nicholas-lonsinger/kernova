# The image KernovaKit's Linux tests run in, on the BASE linux_tests_base names
# (Tools/lib/linux-tests.sh). It reads a tar of the tree to test from stdin,
# then builds and tests the package with its tracked pins.
# KernovaPlatformLinuxTests start their own dbus-daemon; ISO9660WriterTests read
# the image back with xorriso.
ARG BASE
FROM ${BASE}
RUN apt-get update && apt-get install --yes --no-install-recommends dbus xorriso && rm -rf /var/lib/apt/lists/*
WORKDIR /src
ENTRYPOINT ["bash", "-c", "tar -x && . Tools/lib/package-pins.sh && with_package_pins KernovaKit swift build -- && with_package_pins KernovaKit swift test --"]
