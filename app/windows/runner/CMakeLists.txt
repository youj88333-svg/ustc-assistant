cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "default_audio_input.cpp"
  "observation_bridge.cpp"
  "young_json_projection.cpp"
  "young_read_only_observer.cpp"
  "young_business_reader.cpp"
  "$<$<CONFIG:Debug>:${CMAKE_CURRENT_SOURCE_DIR}/young_json_projection_test.cpp>"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
include("webview2_sdk.cmake")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Opt-in pure codec regression. It serializes synthetic method calls and never
# instantiates the audio bridge or accesses Windows audio devices.
add_executable(default_audio_input_codec_test EXCLUDE_FROM_ALL
  "default_audio_input_codec_test.cpp"
)
apply_standard_settings(default_audio_input_codec_test)
target_compile_definitions(default_audio_input_codec_test PRIVATE "NOMINMAX")
target_include_directories(default_audio_input_codec_test PRIVATE "${CMAKE_SOURCE_DIR}")
target_link_libraries(default_audio_input_codec_test PRIVATE flutter_wrapper_plugin)

add_custom_target(run_default_audio_input_codec_test
  COMMAND "$<TARGET_FILE:default_audio_input_codec_test>"
  DEPENDS default_audio_input_codec_test
  WORKING_DIRECTORY "$<TARGET_FILE_DIR:default_audio_input_codec_test>"
  VERBATIM
)
