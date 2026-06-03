#ifndef LIB_MLX_H
#define LIB_MLX_H

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

char *lib_mlx_load_model(const char *config_json);
char *lib_mlx_start_server(int64_t handle, const char *config_json);
char *lib_mlx_stop_server(int64_t handle);
char *lib_mlx_server_status(int64_t handle);
char *lib_mlx_unload_model(int64_t handle);
void lib_mlx_free(void *ptr);

#if defined(__cplusplus)
}
#endif

#endif
