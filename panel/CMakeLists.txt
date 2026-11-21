# SPDX-License-Identifier: GPL-2.0-or-later
cmake_minimum_required(VERSION 3.21)
project(nisse-panel VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
find_package(Qt6 REQUIRED COMPONENTS Core Gui Qml Quick QuickControls2 DBus QuickTest Test)
find_package(LayerShellQt REQUIRED) # the sidebar is a layer-shell surface (N-415a); layer-shell-qt-devel in the build VM
qt_standard_project_setup(REQUIRES 6.5)

qt_add_executable(nisse-panel src/main.cpp)
qt_add_qml_module(nisse-panel
    URI Nisse.Panel
    VERSION 1.0
    QML_FILES qml/Main.qml qml/ChatView.qml qml/AuditView.qml qml/StatusBar.qml qml/ApprovalsView.qml qml/SessionTabs.qml qml/RemoteSwitch.qml qml/KillSwitchBar.qml qml/ConfigView.qml qml/ConnectionBanner.qml qml/DevicesView.qml qml/UndoView.qml
    SOURCES src/DaemonClient.h src/DaemonClient.cpp src/ApprovalNotifier.h src/ApprovalNotifier.cpp
            src/MicWatcher.h src/MicWatcher.cpp src/DesktopNotify.h src/DesktopNotify.cpp src/LauncherBadge.h src/LauncherBadge.cpp
            src/Sidebar.h src/Sidebar.cpp src/PanelService.h src/PanelService.cpp src/LayerShellDock.h src/LayerShellDock.cpp
            src/TrayState.h src/TrayState.cpp src/TrayItem.h src/TrayItem.cpp src/TrayCounts.h
)
target_link_libraries(nisse-panel PRIVATE Qt6::Core Qt6::Gui Qt6::Qml Qt6::Quick Qt6::QuickControls2 Qt6::DBus LayerShellQt::Interface)
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

# The desktop notice message and its "needs you" sound hint (no bus needed).
add_executable(tst_notify tests/tst_notify.cpp src/DesktopNotify.cpp)
target_include_directories(tst_notify PRIVATE src)
target_link_libraries(tst_notify PRIVATE Qt6::Test Qt6::Core Qt6::DBus)
add_test(NAME tst_notify COMMAND tst_notify)
set_tests_properties(tst_notify PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The sidebar rules (open, slide, edge dwell) and the single-instance control surface (no compositor, no bus needed).
add_executable(tst_sidebar tests/tst_sidebar.cpp src/Sidebar.cpp)
target_include_directories(tst_sidebar PRIVATE src)
target_link_libraries(tst_sidebar PRIVATE Qt6::Test Qt6::Core)
add_test(NAME tst_sidebar COMMAND tst_sidebar)
set_tests_properties(tst_sidebar PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The tray item's state mapping and wording (no bus, no window).
add_executable(tst_trayicon tests/tst_trayicon.cpp src/TrayState.cpp)
target_include_directories(tst_trayicon PRIVATE src)
target_link_libraries(tst_trayicon PRIVATE Qt6::Test Qt6::Core)
add_test(NAME tst_trayicon COMMAND tst_trayicon)
set_tests_properties(tst_trayicon PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# The tray item and its menu on a private bus (run under dbus-run-session, so the person's own session bus is never touched).
add_executable(tst_trayitem tests/tst_trayitem.cpp src/TrayItem.cpp src/TrayState.cpp)
target_include_directories(tst_trayitem PRIVATE src)
target_link_libraries(tst_trayitem PRIVATE Qt6::Test Qt6::Core Qt6::DBus)
add_test(NAME tst_trayitem COMMAND dbus-run-session -- $<TARGET_FILE:tst_trayitem>)
set_tests_properties(tst_trayitem PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

add_executable(tst_panelservice tests/tst_panelservice.cpp src/PanelService.cpp src/Sidebar.cpp)
target_include_directories(tst_panelservice PRIVATE src)
target_link_libraries(tst_panelservice PRIVATE Qt6::Test Qt6::Core Qt6::DBus)
add_test(NAME tst_panelservice COMMAND tst_panelservice)
set_tests_properties(tst_panelservice PROPERTIES ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
