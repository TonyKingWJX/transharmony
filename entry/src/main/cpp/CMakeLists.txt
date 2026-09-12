cmake_minimum_required(VERSION 3.5.0)
project(pluginhost)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

add_library(pluginhost SHARED pluginhost.cpp jsvm_runtime.cpp)

target_link_libraries(pluginhost PUBLIC libace_napi.z.so libhilog_ndk.z.so libjsvm.so)
