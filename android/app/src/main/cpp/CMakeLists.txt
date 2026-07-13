cmake_minimum_required(VERSION 3.22.1)
project(attachment_custody)

add_library(attachment_custody SHARED AttachmentCustody.cpp)

find_library(log-lib log)
target_compile_features(attachment_custody PRIVATE cxx_std_20)
target_compile_options(attachment_custody PRIVATE -Wall -Wextra -Werror -fno-exceptions)
target_link_libraries(attachment_custody ${log-lib})
