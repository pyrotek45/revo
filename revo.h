// this file, revo.h is public domain.
#ifndef REVO_FFI_H
#define REVO_FFI_H

#include <stddef.h>
#include <stdint.h>

// mapping of a CRevoData
typedef struct {
  uint64_t tag;
  uint64_t value;
} RevoData;

// function signature all c functions must use
typedef void (*RevoFn)(void *vm, size_t argc, RevoData *argv,
                       RevoData *out_result);

// binding registration
typedef struct {
  const char *name;
  RevoFn fn;
} RevoBinding;
#define REVO_BINDINGS_END {NULL, NULL}

// types
typedef enum {
  revo_number = 0, // bitcasted f64
  revo_string,     // string ptr
  revo_atom,       // atom ID
  revo_function,   // function ID
  revo_table,      // table ID
  revo_tuple       // tuple ID
} RevoType;

// refer to src/root.zig:pub const core_atoms = enum(AtomID);
// by accident, ra_nil is false (but ra_false is not)
typedef enum {
  ra_nil,
  ra_missing,
  ra_undef,
  ra_none,
  ra_no_result,
  ra_false,
  ra_true,
  ra_range,
  ra_ok,
  ra_err,
  ra_some,
} RevoAtom;

// it is often you would want to return these
#define R_NIL()                                                                \
  (RevoData) { .tag = revo_atom, .value = ra_nil }
#define R_BOOL(v)                                                              \
  (RevoData) { .tag = revo_atom, .value = v ? ra_true : ra_false }

// intern a c-allocated string into revo's string pool
// vm must be the pointer passed to your RevoFn
// ptr must be allocated with malloc (revo will free it)
// len is the string length (without null terminator)
// returns the StringID to pass to R_STRING()
typedef uint64_t (*RevoInternFn)(void *vm, uint64_t ptr, size_t len);
extern RevoInternFn revo_intern;

// return a string from a C function
// use with the StringID returned by revo_intern()
#define R_STRING(id)                                                           \
  (RevoData) { .tag = revo_string, .value = id }

// get a global variable by name
// vm must be the pointer passed to your RevoFn
// name_ptr is a pointer to a C string (passed as u64)
// name_len is the string length (without null terminator)
// returns the value, or nil if not found
typedef RevoData (*RevoGetGlobalFn)(void *vm, uint64_t name_ptr, size_t name_len);
extern RevoGetGlobalFn revo_getglobal;

// set a global variable by name
// vm must be the pointer passed to your RevoFn
// name_ptr is a pointer to a C string (passed as u64)
// name_len is the string length (without null terminator)
// value is the value to set
typedef void (*RevoSetGlobalFn)(void *vm, uint64_t name_ptr, size_t name_len, RevoData value);
extern RevoSetGlobalFn revo_setglobal;

// get a value from a table
// vm must be the pointer passed to your RevoFn
// table_id is the table ID (as returned by revo_table in previous calls)
// key is the key to lookup
// returns the value, or nil if not found
typedef RevoData (*RevoTableGetFn)(void *vm, uint64_t table_id, RevoData key);
extern RevoTableGetFn revo_table_get;

// set a value in a table
// vm must be the pointer passed to your RevoFn
// table_id is the table ID
// key is the key to set
// value is the value to set
typedef void (*RevoTableSetFn)(void *vm, uint64_t table_id, RevoData key, RevoData value);
extern RevoTableSetFn revo_table_set;

#define R_EXPORT(...)                                                          \
  __attribute__((visibility("default")))                                       \
  const RevoBinding revo_bindings[] = {__VA_ARGS__, {NULL, NULL}};

#define R_SIG(fname)                                                           \
  void fname(void *vm, size_t argc, RevoData *argv, RevoData *out_result)

#endif
