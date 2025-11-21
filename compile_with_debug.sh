#!/bin/bash
# Compilation script for pgSearch extension with enhanced error reporting

set -euo pipefail

echo "=== ParadeDB pgSearch Extension - Debug Compilation Guide ==="
echo

# Function to check prerequisites
check_prerequisites() {
    echo "1. Checking prerequisites..."

    # Check Rust toolchain
    if ! command -v cargo &> /dev/null; then
        echo "Error: Rust toolchain not found. Install from https://rustup.rs/"
        exit 1
    fi

    # Check pgrx
    if ! cargo install --list | grep -q pgrx; then
        echo "Installing pgrx..."
        cargo install cargo-pgrx --version 0.16.1
    fi

    # Check PostgreSQL development headers
    if ! command -v pg_config &> /dev/null; then
        echo "Error: PostgreSQL development headers not found."
        echo "Install with: brew install postgresql (macOS) or apt-get install postgresql-server-dev-all (Ubuntu)"
        exit 1
    fi

    echo "✓ Prerequisites satisfied"
}

# Function to apply debug patches
apply_debug_patches() {
    echo
    echo "2. Applying debug patches for enhanced error reporting..."

    # Create backup of original files
    cp pg_search/src/postgres/insert.rs pg_search/src/postgres/insert.rs.backup
    cp pg_search/src/postgres/utils.rs pg_search/src/postgres/utils.rs.backup

    # Apply enhanced error handling to insert.rs
    sed -i.tmp 's/.unwrap_or_else(|err| panic!("{err}"));/.unwrap_or_else(|err| {\
        let block = (ctid >> 16) as u32;\
        let offset = (ctid \& 0xFFFF) as u16;\
        panic!("Error processing row at ctid ({}, {}), row_id={}: {}", block, offset, ctid, err);\
    });/' pg_search/src/postgres/insert.rs

    # Enable debug logging in Cargo.toml for pg_search
    if ! grep -q 'log = ' pg_search/Cargo.toml; then
        sed -i.tmp '/\[dependencies\]/a\
log = "0.4"' pg_search/Cargo.toml
    fi

    echo "✓ Debug patches applied"
    echo "  - Original files backed up with .backup extension"
    echo "  - Enhanced error messages now include row ctid information"
}

# Function to set debug build configuration
configure_debug_build() {
    echo
    echo "3. Configuring debug build..."

    # Set debug build in Cargo.toml
    cat >> Cargo.toml.debug << 'EOF'
[profile.debug-with-info]
inherits = "dev"
debug = true
overflow-checks = true
panic = "unwind"
opt-level = 0

[profile.release-with-debug-info]
inherits = "release"
debug = true
strip = false
overflow-checks = true
panic = "abort"  # Change to "unwind" if you need stack traces
EOF

    echo "✓ Debug configuration created"
}

# Function to initialize pgrx for different PostgreSQL versions
init_pgrx() {
    echo
    echo "4. Initializing pgrx for PostgreSQL versions..."

    # Initialize pgrx with supported PostgreSQL versions
    cargo pgrx init --pg14 --pg15 --pg16 --pg17

    echo "✓ pgrx initialized"
}

# Function to compile with debug information
compile_debug() {
    local pg_version=${1:-17}

    echo
    echo "5. Compiling pgSearch extension with debug info for PostgreSQL ${pg_version}..."

    # Set debug environment variables for more detailed error reporting
    export RUST_BACKTRACE=full
    export RUST_LOG=debug
    export CARGO_PROFILE_RELEASE_DEBUG=true
    export CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS=true

    # Compile with debug configuration
    cd pg_search

    # Use debug profile for more detailed error information
    CARGO_PROFILE=debug cargo pgrx install --pg${pg_version} --verbose

    echo "✓ Compilation completed with debug information"
    echo "  - Debug symbols enabled"
    echo "  - Overflow checking enabled"
    echo "  - Full backtrace enabled"
    echo "  - Enhanced error messages enabled"
}

# Function to create debugging helper script
create_debug_helpers() {
    echo
    echo "6. Creating debugging helper scripts..."

cat > debug_helpers.sql << 'EOF'
-- Helper SQL functions for debugging pgSearch index creation issues

-- Function to safely test index creation on a subset of data
CREATE OR REPLACE FUNCTION safe_create_pgsearch_index(
    table_name TEXT,
    index_name TEXT,
    config_json JSONB DEFAULT '{}',
    limit_rows INTEGER DEFAULT 1000
) RETURNS TEXT AS $$
DECLARE
    temp_table_name TEXT := table_name || '_debug_subset';
    result TEXT;
BEGIN
    -- Create a small subset table for testing
    EXECUTE format('DROP TABLE IF EXISTS %I', temp_table_name);
    EXECUTE format('CREATE TABLE %I AS SELECT * FROM %I LIMIT %s',
                  temp_table_name, table_name, limit_rows);

    BEGIN
        -- Try to create index on subset
        EXECUTE format('CALL paradedb.create_bm25_index(%L, %L, %L)',
                      temp_table_name, index_name || '_debug', config_json);
        result := 'SUCCESS: Index created on ' || limit_rows || ' rows';

    EXCEPTION WHEN OTHERS THEN
        result := 'FAILED at row subset: ' || SQLERRM;
    END;

    -- Clean up
    EXECUTE format('DROP TABLE IF EXISTS %I', temp_table_name);

    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Function to find problematic rows by binary search
CREATE OR REPLACE FUNCTION find_problematic_rows(
    table_name TEXT,
    index_config JSONB DEFAULT '{}',
    max_iterations INTEGER DEFAULT 20
) RETURNS TABLE(row_range TEXT, error_message TEXT) AS $$
DECLARE
    total_rows INTEGER;
    min_row INTEGER := 1;
    max_row INTEGER;
    mid_row INTEGER;
    iteration INTEGER := 0;
    temp_table TEXT;
    success BOOLEAN;
BEGIN
    -- Get total row count
    EXECUTE format('SELECT COUNT(*) FROM %I', table_name) INTO total_rows;
    max_row := total_rows;

    WHILE min_row < max_row AND iteration < max_iterations LOOP
        iteration := iteration + 1;
        mid_row := (min_row + max_row) / 2;
        temp_table := table_name || '_debug_' || iteration;

        -- Create subset table
        EXECUTE format('DROP TABLE IF EXISTS %I', temp_table);
        EXECUTE format('CREATE TABLE %I AS
                       SELECT *, ROW_NUMBER() OVER() as debug_row_num
                       FROM %I
                       WHERE ROW_NUMBER() OVER() BETWEEN %s AND %s',
                      temp_table, table_name, min_row, mid_row);

        -- Test index creation
        BEGIN
            EXECUTE format('CALL paradedb.create_bm25_index(%L, %L, %L)',
                          temp_table, temp_table || '_idx', index_config);
            success := TRUE;
        EXCEPTION WHEN OTHERS THEN
            success := FALSE;
            row_range := format('Rows %s-%s', min_row, mid_row);
            error_message := SQLERRM;
            RETURN NEXT;
        END;

        -- Clean up
        EXECUTE format('DROP TABLE IF EXISTS %I', temp_table);

        IF success THEN
            min_row := mid_row + 1;
        ELSE
            max_row := mid_row;
        END IF;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Function to analyze field data types and sizes that might cause issues
CREATE OR REPLACE FUNCTION analyze_field_issues(table_name TEXT)
RETURNS TABLE(column_name TEXT, data_type TEXT, max_length INTEGER, has_nulls BOOLEAN, sample_problematic_values TEXT) AS $$
BEGIN
    RETURN QUERY
    SELECT
        cols.column_name::TEXT,
        cols.data_type::TEXT,
        CASE
            WHEN cols.data_type IN ('text', 'varchar', 'char') THEN
                (SELECT MAX(LENGTH(column_value::TEXT)) FROM (
                    SELECT unnest(array_agg(cols.column_name)) as column_value
                    FROM information_schema.columns
                ) t)
            ELSE NULL
        END as max_length,
        EXISTS(SELECT 1 FROM information_schema.columns WHERE table_name = analyze_field_issues.table_name AND column_name = cols.column_name AND is_nullable = 'YES') as has_nulls,
        NULL::TEXT as sample_problematic_values
    FROM information_schema.columns cols
    WHERE cols.table_name = analyze_field_issues.table_name;
END;
$$ LANGUAGE plpgsql;
EOF

    echo "✓ Debug helper SQL functions created in debug_helpers.sql"
}

# Function to test the debug build
test_debug_build() {
    echo
    echo "7. Testing debug build..."

    # Create test database and table if not exists
    psql -d postgres -c "DROP DATABASE IF EXISTS pgsearch_debug_test;" 2>/dev/null || true
    psql -d postgres -c "CREATE DATABASE pgsearch_debug_test;"

    # Test basic functionality
    psql -d pgsearch_debug_test -c "
        CREATE EXTENSION pg_search;
        CREATE TABLE test_debug (id SERIAL PRIMARY KEY, content TEXT);
        INSERT INTO test_debug (content) VALUES ('test content'), ('more test data');
        CALL paradedb.create_bm25_index('test_debug', 'test_debug_idx', '{}');
        SELECT * FROM test_debug WHERE test_debug @@@ paradedb.parse('test');
        DROP TABLE test_debug;
    " || echo "WARNING: Basic test failed - check error messages for row information"

    echo "✓ Debug build test completed"
}

# Function to provide usage instructions
print_usage_instructions() {
    echo
    echo "=== Usage Instructions ==="
    echo
    echo "After compilation, when you encounter indexing errors:"
    echo
    echo "1. Check PostgreSQL logs for enhanced error messages:"
    echo "   tail -f /var/log/postgresql/postgresql-*.log"
    echo
    echo "2. Use debug helper functions:"
    echo "   psql -d your_database -f debug_helpers.sql"
    echo "   SELECT * FROM safe_create_pgsearch_index('your_table', 'test_idx', '{}', 100);"
    echo "   SELECT * FROM find_problematic_rows('your_table');"
    echo "   SELECT * FROM analyze_field_issues('your_table');"
    echo
    echo "3. Environment variables for runtime debugging:"
    echo "   export RUST_BACKTRACE=full"
    echo "   export RUST_LOG=debug"
    echo "   export PG_SEARCH_DEBUG=1"
    echo
    echo "4. Look for error messages like:"
    echo "   'Error processing row at ctid (123, 45), row_id=8077365: index out of bounds...'"
    echo
    echo "5. To revert debug changes:"
    echo "   mv pg_search/src/postgres/insert.rs.backup pg_search/src/postgres/insert.rs"
    echo "   mv pg_search/src/postgres/utils.rs.backup pg_search/src/postgres/utils.rs"
    echo
    echo "=== Additional Debugging Tips ==="
    echo
    echo "- Check for extremely large arrays or text fields"
    echo "- Look for Unicode issues in text data"
    echo "- Monitor memory usage during indexing"
    echo "- Consider using smaller batch sizes with 'paradedb.mutable_segment_rows'"
}

# Main execution
main() {
    local pg_version=${1:-17}

    echo "Starting debug compilation for PostgreSQL ${pg_version}..."

    check_prerequisites
    apply_debug_patches
    configure_debug_build
    init_pgrx
    compile_debug $pg_version
    create_debug_helpers
    test_debug_build
    print_usage_instructions

    echo
    echo "=== Compilation Complete ==="
    echo "The pgSearch extension has been compiled with enhanced error reporting."
    echo "When indexing fails, you should now see detailed row information in the error messages."
}

# Run main function with command line arguments
main "$@"