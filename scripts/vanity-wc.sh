#!/bin/bash

THIS_DIR=$(cd $(dirname $0) && pwd)

RUST_WC=$(find $THIS_DIR/../server/src -type f -name '*.rs' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)
PY_WC=$(find $THIS_DIR/../tests -type f -name '*.py' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)
JS_WC=$(find $THIS_DIR/../shared $THIS_DIR/../server/static -type f -name '*.js' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)
TF_WC=$(find $THIS_DIR/../shared $THIS_DIR/../infra -type f -name '*.tf' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)
SQL_WC=$(find $THIS_DIR/../server/migrations -type f -name '*.sql' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)
DOC_WC=$(find $THIS_DIR/../docs -type f -name '*.md' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)
SFT_WC=$(find $THIS_DIR/../ios -type f -name '*.swift' -exec wc -l {} + | tail -1 | cut -d ' ' -f 5)

echo "rust: $RUST_WC"
echo "python: $PY_WC"
echo "javascript: $JS_WC"
echo "terraform: $TF_WC"
echo "sql: $SQL_WC"
echo "docs: $DOC_WC"
echo "swift: $SFT_WC"