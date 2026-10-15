cmake_minimum_required(VERSION 3.14)
project(ustc_notification_probe LANGUAGES CXX)
add_executable(notification_probe
  notification_probe.cpp
  ../../app/windows/runner/notification_platform.cpp)
target_compile_features(notification_probe PRIVATE cxx_std_20)
target_compile_options(notification_probe PRIVATE /W4 /EHsc /utf-8)
target_compile_definitions(notification_probe PRIVATE UNICODE _UNICODE NOMINMAX)
target_include_directories(notification_probe PRIVATE ../../app/windows/runner)
target_link_libraries(notification_probe PRIVATE windowsapp ole32 shell32 propsys advapi32 uuid)

# Pure synthetic activation/IPC boundary probe. No notification registration,
# scheduling, history access, external protocol launch, or business database.
add_executable(activation_probe
  activation_probe.cpp
  ../../app/windows/runner/notification_platform.cpp
  ../../app/windows/runner/notification_activation.cpp)
target_compile_features(activation_probe PRIVATE cxx_std_20)
target_compile_options(activation_probe PRIVATE /W4 /WX /EHsc /utf-8)
target_compile_definitions(activation_probe PRIVATE UNICODE _UNICODE NOMINMAX)
target_include_directories(activation_probe PRIVATE ../../app/windows/runner)
target_link_libraries(activation_probe PRIVATE windowsapp ole32 shell32 propsys advapi32 uuid)
