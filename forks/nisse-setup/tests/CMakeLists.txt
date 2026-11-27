# SPDX-FileCopyrightText: 2026 nisse
# SPDX-License-Identifier: GPL-2.0-or-later

# nisse's tests of nisse's code in this fork (N-306e). Upstream has none.
find_package(Qt6 ${QT_MIN_VERSION} NO_MODULE REQUIRED COMPONENTS Core Test)

add_executable(choiceset_test
    choiceset_test.cpp
    ${CMAKE_SOURCE_DIR}/src/auth/choiceset.cpp
)
target_include_directories(choiceset_test PRIVATE ${CMAKE_SOURCE_DIR}/src/auth)
target_link_libraries(choiceset_test PRIVATE Qt6::Core Qt6::Test)
add_test(NAME choiceset_test COMMAND choiceset_test)

add_executable(choiceslisting_test
    choiceslisting_test.cpp
    ${CMAKE_SOURCE_DIR}/modules/choicesutil/choiceslisting.cpp
)
target_include_directories(choiceslisting_test PRIVATE ${CMAKE_SOURCE_DIR}/modules/choicesutil)
target_link_libraries(choiceslisting_test PRIVATE Qt6::Core Qt6::Test)
add_test(NAME choiceslisting_test COMMAND choiceslisting_test)

add_executable(launcherlisting_test
    launcherlisting_test.cpp
    ${CMAKE_SOURCE_DIR}/modules/choicesutil/launcherlisting.cpp
)
target_include_directories(launcherlisting_test PRIVATE ${CMAKE_SOURCE_DIR}/modules/choicesutil)
target_link_libraries(launcherlisting_test PRIVATE Qt6::Core Qt6::Test KF6::ConfigCore)
add_test(NAME launcherlisting_test COMMAND launcherlisting_test)
