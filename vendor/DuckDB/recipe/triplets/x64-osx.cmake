# vcpkg's x64-osx, for macOS 14, plus two flags. Apple clang 21 (Xcode 26.5 has it, 26.3 not) added
# -Wdefault-const-init-var-unsafe, and MariaDB Connector/C 3.4.7 (ma_tls.c) trips it
# under the port's -Werror. An older clang doesn't know the name, and under -Werror an
# unknown warning name fails the build: -Wno-unknown-warning-option has it skipped.
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES x86_64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 14.0)
set(VCPKG_C_FLAGS "-Wno-unknown-warning-option -Wno-error=default-const-init-var-unsafe")
set(VCPKG_CXX_FLAGS "-Wno-unknown-warning-option -Wno-error=default-const-init-var-unsafe")
