# Enhanced Row Error Reporting for pgSearch

## Problem Statement

When pgSearch fails to index rows due to errors like "index out of bounds: the len is 512 but the index is 512", there's no way to identify which specific row caused the failure. This makes debugging large dataset indexing failures extremely difficult.

## Current State Analysis

### Error Locations
1. **Serial Insert Path** (`postgres/insert.rs:294`)
   - Has `ctid: u64` available
   - Uses: `.unwrap_or_else(|err| panic!("{err}"))`
   - **Missing row context in error**

2. **Parallel Build Path** (`postgres/build_parallel.rs:507`)
   - Has `ctid_u64` available
   - Uses: `.unwrap_or_else(|e| panic!("{e}"))`
   - **Missing row context in error**

3. **MVCC Directory Path** (`index/directory/mvcc.rs:686`)
   - Has row context but generic error: `panic!("Failed to create document from row: {e}")`

### Existing Error Infrastructure

- `IndexError` enum in `index/writer/index.rs:427-442`
- Proper error propagation with `#[error]` attributes
- Already includes contextual errors like `KeyIdNull(String)`

## Proposed Solution

### 1. Extend IndexError with Row Context

Add new error variants that include row identification:

```rust
#[derive(Error, Debug)]
pub enum IndexError {
    // ... existing variants ...

    #[error("Error processing row at ctid ({block}, {offset}) [row_id={ctid}]: {source}")]
    RowProcessingError {
        ctid: u64,
        block: u32,
        offset: u16,
        source: Box<dyn std::error::Error + Send + Sync>,
    },

    #[error("Field '{field}' in row at ctid ({block}, {offset}) [row_id={ctid}]: {source}")]
    FieldProcessingError {
        field: String,
        ctid: u64,
        block: u32,
        offset: u16,
        source: Box<dyn std::error::Error + Send + Sync>,
    },
}
```

### 2. Add Row Context Helper

Create utility function for consistent ctid decomposition:

```rust
pub fn decompose_ctid(ctid: u64) -> (u32, u16) {
    let block = (ctid >> 16) as u32;
    let offset = (ctid & 0xFFFF) as u16;
    (block, offset)
}
```

### 3. Enhance row_to_search_document

Modify the function signature to include row context and use proper error mapping:

```rust
pub unsafe fn row_to_search_document<'a>(
    categorized_fields: impl Iterator<Item = (...)>,
    document: &mut tantivy::TantivyDocument,
    ctid: u64,  // Add ctid parameter
) -> Result<(), IndexError> {
    for (datum, isnull, search_field, categorized_field_data) in categorized_fields {
        let field_name = search_field.field_name().to_string();

        // Wrap individual field processing with row context
        if *is_array {
            for value in TantivyValue::try_from_datum_array(datum, *base_oid)
                .map_err(|source| {
                    let (block, offset) = decompose_ctid(ctid);
                    IndexError::FieldProcessingError {
                        field: field_name.clone(),
                        ctid,
                        block,
                        offset,
                        source: Box::new(source),
                    }
                })? {
                // ... processing ...
            }
        }
        // Similar for JSON and regular fields...
    }
    Ok(())
}
```

### 4. Update Call Sites

**Serial Insert Path:**
```rust
row_to_search_document(
    mode.categorized_fields.iter().map(/*...*/),
    &mut search_document,
    ctid,  // Pass ctid
)
.unwrap_or_else(|err| {
    // Use pgrx error reporting instead of panic
    pgrx::error!("Index creation failed: {}", err);
});
```

**Parallel Build Path:**
```rust
row_to_search_document(
    build_state.categorized_fields.iter().map(/*...*/),
    &mut doc,
    ctid_u64,  // Pass ctid
)
.unwrap_or_else(|err| {
    pgrx::error!("Parallel index build failed: {}", err);
});
```

## Benefits of This Approach

1. **Follows existing patterns**: Uses the established `IndexError` enum and error propagation
2. **Backward compatible**: Existing error variants remain unchanged
3. **Consistent error format**: All row-related errors will have the same format
4. **Upstream ready**: Uses proper error handling instead of debug prints
5. **Informative**: Provides ctid decomposition for easier row identification
6. **Extensible**: Easy to add field-level context for more specific errors

## Implementation Plan

1. **Phase 1**: Extend `IndexError` enum with row context variants
2. **Phase 2**: Add ctid decomposition utility function
3. **Phase 3**: Modify `row_to_search_document` signature and implementation
4. **Phase 4**: Update call sites in insert.rs and build_parallel.rs
5. **Phase 5**: Add tests for error reporting
6. **Phase 6**: Update documentation

## Testing Strategy

1. **Unit tests**: Test error construction and message formatting
2. **Integration tests**: Create tables with problematic data that trigger errors
3. **Error format verification**: Ensure error messages include row information
4. **Backward compatibility**: Ensure existing error paths still work

## Alternative Considered

- **Logging approach**: Just add logging without changing error types
  - Rejected because logs might not reach users in hosted environments
- **Debug-only approach**: Only include row info in debug builds
  - Rejected because production users need this information most
- **Global error context**: Thread-local storage for row context
  - Rejected because it's harder to reason about and not idiomatic Rust

## Migration Path

This enhancement is backward compatible and doesn't break existing APIs. The error messages will be more informative but the error handling logic remains the same.