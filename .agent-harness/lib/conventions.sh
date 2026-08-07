#!/usr/bin/env bash

_CONVENTIONS_LIB_DIR=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
. "$_CONVENTIONS_LIB_DIR/convention_store.sh"
. "$_CONVENTIONS_LIB_DIR/convention_authority.sh"
. "$_CONVENTIONS_LIB_DIR/convention_applicability.sh"
. "$_CONVENTIONS_LIB_DIR/convention_review.sh"
. "$_CONVENTIONS_LIB_DIR/convention_inspection.sh"
unset _CONVENTIONS_LIB_DIR
