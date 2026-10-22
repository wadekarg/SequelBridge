# vcpkg's arm64-osx, for macOS 14, plus one flag. Apple clang 21 added
# -Wdefault-const-init-var-unsafe, and MariaDB Connector/C 3.4.7 (ma_tls.c) trips it
# under the port's -Werror.
set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES arm64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 14.0)
set(VCPKG_C_FLAGS "-Wno-error=default-const-init-var-unsafe")
set(VCPKG_CXX_FLAGS "-Wno-error=default-const-init-var-unsafe")
