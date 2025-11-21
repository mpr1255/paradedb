// Debug patch for insert.rs to add row identification to error messages
// Apply this change to pg_search/src/postgres/insert.rs line 294

// REPLACE THIS LINE:
// .unwrap_or_else(|err| panic!("{err}"));

// WITH THIS ENHANCED ERROR HANDLING:
.unwrap_or_else(|err| {
    // Convert ctid back to block and offset for easier identification
    let block = (ctid >> 16) as u32;
    let offset = (ctid & 0xFFFF) as u16;

    // Enhanced panic message with row context
    panic!(
        "Error processing row at ctid ({}, {}), row_id={}: {}",
        block, offset, ctid, err
    );
});

// ALSO ENHANCE row_to_search_document function in postgres/utils.rs
// Add field-level error context by modifying lines 410-446 to catch errors per field:

pub unsafe fn row_to_search_document_debug<'a>(
    categorized_fields: impl Iterator<
        Item = (
            pg_sys::Datum,
            bool,
            &'a SearchField,
            &'a CategorizedFieldData,
        ),
    >,
    document: &mut tantivy::TantivyDocument,
    ctid: u64, // Add ctid parameter for error context
) -> Result<(), IndexError> {
    for (
        datum,
        isnull,
        search_field,
        CategorizedFieldData {
            base_oid,
            is_key_field,
            is_array,
            is_json,
            ..
        },
    ) in categorized_fields
    {
        if isnull && *is_key_field {
            return Err(IndexError::KeyIdNull(search_field.field_name().to_string()));
        }

        if isnull {
            continue;
        }

        // Wrap each field processing with error context
        let field_name = search_field.field_name().to_string();

        if *is_array {
            for value in TantivyValue::try_from_datum_array(datum, *base_oid)
                .map_err(|e| {
                    // Log additional context for array processing errors
                    eprintln!("Array processing error for field '{}' in row ctid={}: {:?}", field_name, ctid, e);
                    e
                })? {
                document.add_field_value(search_field.field(), &OwnedValue::from(value));
            }
        } else if *is_json {
            for value in TantivyValue::try_from_datum_json(datum, *base_oid)
                .map_err(|e| {
                    eprintln!("JSON processing error for field '{}' in row ctid={}: {:?}", field_name, ctid, e);
                    e
                })? {
                document.add_field_value(search_field.field(), &OwnedValue::from(value));
            }
        } else {
            let tv = TantivyValue::try_from_datum(datum, *base_oid)
                .map_err(|e| {
                    eprintln!("Datum conversion error for field '{}' in row ctid={}: {:?}", field_name, ctid, e);
                    e
                })?;
            document.add_field_value(search_field.field(), &OwnedValue::from(tv));
        }
    }
    Ok(())
}