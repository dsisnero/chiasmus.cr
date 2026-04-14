#!/usr/bin/env bash
set -euo pipefail

# Simple TypeScript inventory generator for chiasmus port

ROOT_DIR="${1:-$(pwd)}"
SOURCE_PATH="${2:-vendor/chiasmus}"
OUTPUT_DIR="${3:-plans/inventory}"

mkdir -p "${OUTPUT_DIR}"

# Create TypeScript port inventory
PORT_INVENTORY="${OUTPUT_DIR}/typescript_port_inventory.tsv"
echo -e "source_id\tkind\tstatus\tcrystal_refs\tnotes" > "${PORT_INVENTORY}"

# Create TypeScript source parity manifest
SOURCE_PARITY="${OUTPUT_DIR}/typescript_source_parity.tsv"
echo -e "source_api_id\tstatus\tcrystal_refs\tnotes" > "${SOURCE_PARITY}"

# Create TypeScript test parity manifest
TEST_PARITY="${OUTPUT_DIR}/typescript_test_parity.tsv"
echo -e "source_test_id\tstatus\tcrystal_refs\tnotes" > "${TEST_PARITY}"

# Find TypeScript files and extract basic information
find "${SOURCE_PATH}" -name "*.ts" -type f | while read -r file; do
    rel_path="${file#${SOURCE_PATH}/}"
    
    # Check if it's a test file
    if [[ "$rel_path" == *".test.ts" || "$rel_path" == *".spec.ts" || "$rel_path" == *"/test/"* || "$rel_path" == *"/tests/"* ]]; then
        # Extract test names (simplified)
        grep -E "^(describe|it|test)\s*\(" "$file" | while read -r line; do
            # Extract test name
            test_name=$(echo "$line" | sed -E 's/^(describe|it|test)\s*\(\s*[\"\047]([^\"\047]+)[\"\047].*/\2/' | head -1)
            if [[ -n "$test_name" ]]; then
                test_id="${rel_path}::test::${test_name}"
                echo -e "${test_id}\tmissing\t-\t" >> "${TEST_PARITY}"
                echo -e "${test_id}\ttest\tmissing\t-\t" >> "${PORT_INVENTORY}"
            fi
        done
    else
        # Extract function and class names (simplified)
        grep -E "^(export\s+)?(function|class|interface|type|const|let|var)\s+[A-Za-z_]" "$file" | while read -r line; do
            # Extract identifier name
            if echo "$line" | grep -q "^\s*export\s"; then
                # Remove export keyword
                line=$(echo "$line" | sed 's/^\s*export\s\+//')
            fi
            
            if echo "$line" | grep -q "^function\s"; then
                name=$(echo "$line" | sed -E 's/^function\s+([A-Za-z_][A-Za-z0-9_]*).*/\1/')
                kind="function"
            elif echo "$line" | grep -q "^class\s"; then
                name=$(echo "$line" | sed -E 's/^class\s+([A-Za-z_][A-Za-z0-9_]*).*/\1/')
                kind="class"
            elif echo "$line" | grep -q "^interface\s"; then
                name=$(echo "$line" | sed -E 's/^interface\s+([A-Za-z_][A-Za-z0-9_]*).*/\1/')
                kind="interface"
            elif echo "$line" | grep -q "^type\s"; then
                name=$(echo "$line" | sed -E 's/^type\s+([A-Za-z_][A-Za-z0-9_]*).*/\1/')
                kind="type"
            elif echo "$line" | grep -q "^(const|let|var)\s"; then
                name=$(echo "$line" | sed -E 's/^(const|let|var)\s+([A-Za-z_][A-Za-z0-9_]*).*/\2/')
                kind="variable"
            else
                continue
            fi
            
            if [[ -n "$name" ]]; then
                source_id="${rel_path}::${kind}::${name}"
                echo -e "${source_id}\tmissing\t-\t" >> "${SOURCE_PARITY}"
                echo -e "${source_id}\t${kind}\tmissing\t-\t" >> "${PORT_INVENTORY}"
            fi
        done
    fi
done

echo "Generated TypeScript inventory:"
echo "  - ${PORT_INVENTORY}"
echo "  - ${SOURCE_PARITY}"
echo "  - ${TEST_PARITY}"