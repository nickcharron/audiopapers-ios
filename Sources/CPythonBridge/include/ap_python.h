#ifndef AP_PYTHON_H
#define AP_PYTHON_H

/* The one place the app touches CPython: start it once, then call functions in
 * audiopapers_core.bridge by name with JSON arguments, getting its JSON string back. */

#ifdef __cplusplus
extern "C" {
#endif

/* Called by Python during a long job (see bridge.ingest), from whichever thread made the call. */
typedef void (*ap_progress_fn)(void *context, long done, long total);

/* Starts Python. `home` is the bundled Python's home, or NULL to use this machine's own Python.
 * `app_path` is where the audiopapers_core package is found. `pycache_prefix` is somewhere
 * writable for compiled bytecode, since an app bundle isn't, or NULL. Returns 0 on success;
 * otherwise *error is a message to release with ap_python_free. */
int ap_python_start(const char *home, const char *app_path, const char *pycache_prefix, char **error);

/* Calls audiopapers_core.bridge.<function>(*args, **kwargs), both given as JSON (`kwargs_json`
 * may be NULL). With `progress`, also passes a progress= object whose onProgress calls it.
 * Safe from any thread. Always returns JSON in the bridge's own shape, to release with
 * ap_python_free. */
char *ap_python_call(const char *function, const char *args_json, const char *kwargs_json,
                     ap_progress_fn progress, void *context);

void ap_python_free(char *text);

#ifdef __cplusplus
}
#endif

#endif
