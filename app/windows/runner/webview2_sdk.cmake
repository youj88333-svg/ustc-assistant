# Native WebView2 SDK is pinned independently of browser runtime patch levels.
# Supply USTC_WEBVIEW2_SDK_ROOT when using a cache outside the standard NuGet path.
set(USTC_WEBVIEW2_SDK_VERSION "1.0.3967.48")
set(USTC_WEBVIEW2_SDK_ROOT "$ENV{USERPROFILE}/.nuget/packages/microsoft.web.webview2/${USTC_WEBVIEW2_SDK_VERSION}"
    CACHE PATH "Microsoft WebView2 SDK package directory")
if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64")
  set(USTC_WEBVIEW2_ARCH "arm64")
elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(USTC_WEBVIEW2_ARCH "x64")
else()
  set(USTC_WEBVIEW2_ARCH "x86")
endif()
set(USTC_WEBVIEW2_NATIVE "${USTC_WEBVIEW2_SDK_ROOT}/build/native")
if(NOT EXISTS "${USTC_WEBVIEW2_NATIVE}/include/WebView2.h" OR
   NOT EXISTS "${USTC_WEBVIEW2_NATIVE}/${USTC_WEBVIEW2_ARCH}/WebView2LoaderStatic.lib")
  message(FATAL_ERROR "Install Microsoft.Web.WebView2 ${USTC_WEBVIEW2_SDK_VERSION} in the NuGet cache or set USTC_WEBVIEW2_SDK_ROOT")
endif()
target_include_directories(${BINARY_NAME} SYSTEM PRIVATE "${USTC_WEBVIEW2_NATIVE}/include")
target_link_libraries(${BINARY_NAME} PRIVATE
  "${USTC_WEBVIEW2_NATIVE}/${USTC_WEBVIEW2_ARCH}/WebView2LoaderStatic.lib"
  "ole32.lib" "oleaut32.lib" "urlmon.lib" "version.lib" "shlwapi.lib")
