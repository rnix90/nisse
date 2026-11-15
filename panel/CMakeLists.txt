# SPDX-License-Identifier: GPL-2.0-or-later
cmake_minimum_required(VERSION 3.21)
project(nisse-panel VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 DBus QuickTest Test)
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(nisse-panel src/main.cpp)
qt_add_qml_module(nisse-panel
    URI Nisse.Panel
    VERSION 1.0
    QML_FILES qml/Main.qml qml/ChatView.qml qml/AuditView.qml qml/StatusBar.qml qml/ApprovalsView.qml qml/SessionTabs.qml qml/RemoteSwitch.qml qml/KillSwitchBar.qml qml/ConfigView.qml qml/ConnectionBanner.qml
    SOURCES src/DaemonClient.h src/DaemonClient.cpp src/ApprovalNotifier.h src/ApprovalNotifier.cpp
            src/MicWatcher.h src/MicWatcher.cpp src/DesktopNotify.h src/DesktopNotify.cpp src/LauncherBadge.h src/LauncherBadge.cpp
)
target_link_libraries(nisse-panel PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::DBus)
install(TARGETS nisse-panel RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

enable_testing()
add_executable(tst_chat tests/tst_main.cpp)
target_compile_definitions(tst_chat PRIVATE QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests")
target_link_libraries(tst_chat PRIVATE Qt6::QuickTest Qt6::Quick)
add_test(NAME tst_chat COMMAND tst_chat)
set_tests_properties(tst_chat PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The notification policy and the microphone check (plain Qt Test, no window).
add_executable(tst_notifier tests/tst_notifier.cpp src/ApprovalNotifier.cpp src/MicWatcher.cpp)
target_compile_definitions(tst_notifier PRIVATE FIXTURE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/tests/fixtures")
target_include_directories(tst_notifier PRIVATE src)
target_link_libraries(tst_notifier PRIVATE Qt6::Test Qt6::Core)
add_test(NAME tst_notifier COMMAND tst_notifier)
set_tests_properties(tst_notifier PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The taskbar badge message and its change-only sending (no bus needed).
add_executable(tst_badge tests/tst_badge.cpp src/LauncherBadge.cpp)
target_include_directories(tst_badge PRIVATE src)
target_link_libraries(tst_badge PRIVATE Qt6::Test Qt6::Core Qt6::DBus)
add_test(NAME tst_badge COMMAND tst_badge)
set_tests_properties(tst_badge PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
