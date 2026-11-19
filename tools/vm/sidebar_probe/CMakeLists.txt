# SPDX-License-Identifier: GPL-2.0-or-later
# The N-415a spike probe. Build in the Fedora build VM (needs layer-shell-qt-devel and qt6-qtdeclarative-devel):
#   cmake -S tools/vm/sidebar_probe -B /tmp/sbp -G Ninja && cmake --build /tmp/sbp
cmake_minimum_required(VERSION 3.20)
project(sidebar_probe LANGUAGES CXX)
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_AUTOMOC ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick)
find_package(LayerShellQt REQUIRED)
add_executable(sidebar_probe sidebar_probe.cpp)
target_link_libraries(sidebar_probe PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick LayerShellQt::Interface)
