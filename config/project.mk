# Makefile 配置入口：复用 config/project.env，避免版本号重复维护。
THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(THIS_DIR)/project.env

PROJECT_ROOT := $(abspath $(THIS_DIR)/..)
SOURCES_DIR  := $(PROJECT_ROOT)/sources
OUTPUT_DIR   := $(PROJECT_ROOT)/output
FIRMWARE_DIR := $(PROJECT_ROOT)/firmware
CONFIG_DIR   := $(PROJECT_ROOT)/config
SCRIPTS_DIR  := $(PROJECT_ROOT)/scripts
