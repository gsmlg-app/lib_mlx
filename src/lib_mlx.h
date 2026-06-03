#ifndef LIB_MLX_H
#define LIB_MLX_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

// Loads a local model path and returns a JSON result:
// {"ok":true,"handle":1,"status":"ready","model_id":"..."}.
//
// The v1 inference path is HTTP-only. FFI is reserved for model/server
// lifecycle management and returns retained JSON strings that callers must free
// with lib_mlx_free.
char *lib_mlx_load_model(const char *config_json);

// Starts the localhost OpenAI-compatible server for a loaded model handle.
char *lib_mlx_start_server(int64_t handle, const char *config_json);

// Stops the server attached to a loaded model handle.
char *lib_mlx_stop_server(int64_t handle);

// Returns JSON model/server status for a loaded model handle.
char *lib_mlx_server_status(int64_t handle);

// Stops any server and unloads the resident model handle.
char *lib_mlx_unload_model(int64_t handle);

// Frees strings returned from lib_mlx_* functions.
void lib_mlx_free(void *ptr);

#if defined(__cplusplus)
}
#endif

#endif
