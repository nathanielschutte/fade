#!/bin/bash

THIS_DIR=$(cd $(dirname $0) && pwd)

RUST_WC=$(find $THIS_DIR/../server/src -type f -name '*.rs' -exec wc -l --total=only {} +)
PY_WC=$(find $THIS_DIR/../tests -type f -name '*.py' -exec wc -l --total=only {} +)
JS_WC=$(find $THIS_DIR/../shared $THIS_DIR/../server/static -type f -name '*.js' -exec wc -l --total=only {} +)
TF_WC=$(find $THIS_DIR/../shared $THIS_DIR/../infra -type f -name '*.tf' -exec wc -l --total=only {} +)
SQL_WC=$(find $THIS_DIR/../server/migrations -type f -name '*.sql' -exec wc -l --total=only {} +)
DOC_WC=$(find $THIS_DIR/../docs -type f -name '*.md' -exec wc -l --total=only {} +)

echo "rust: $RUST_WC"
echo "python: $PY_WC"
echo "javascript: $JS_WC"
echo "terraform: $TF_WC"
echo "sql: $SQL_WC"
echo "docs: $DOC_WC"