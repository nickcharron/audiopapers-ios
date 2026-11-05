#define PY_SSIZE_T_CLEAN
#if __has_include(<Python/Python.h>)
#include <Python/Python.h>
#else
#include <Python.h>
#endif

#include <stdlib.h>
#include <string.h>

#include "ap_python.h"

static PyObject *bridge_module = NULL;
static PyObject *json_loads = NULL;
static PyObject *simple_namespace = NULL;

typedef struct {
    ap_progress_fn fn;
    void *context;
} progress_target;

static char *copy_text(const char *text) {
    size_t size = strlen(text) + 1;
    char *copy = malloc(size);
    if (copy != NULL) {
        memcpy(copy, text, size);
    }
    return copy;
}

/* The current Python exception as text, clearing it. */
static char *exception_text(void) {
    PyObject *type = NULL, *value = NULL, *trace = NULL;
    PyErr_Fetch(&type, &value, &trace);
    if (type == NULL) {
        return copy_text("Unknown Python error");
    }
    PyErr_NormalizeException(&type, &value, &trace);
    PyObject *traceback = PyImport_ImportModule("traceback");
    PyObject *lines = traceback == NULL ? NULL
        : PyObject_CallMethod(traceback, "format_exception", "OOO", type, value != NULL ? value : Py_None, trace != NULL ? trace : Py_None);
    PyObject *empty = lines == NULL ? NULL : PyUnicode_FromString("");
    PyObject *joined = empty == NULL ? NULL : PyUnicode_Join(empty, lines);
    const char *utf8 = joined == NULL ? NULL : PyUnicode_AsUTF8(joined);
    char *text = copy_text(utf8 != NULL ? utf8 : "Python error (and couldn't format it)");
    PyErr_Clear();
    Py_XDECREF(joined);
    Py_XDECREF(empty);
    Py_XDECREF(lines);
    Py_XDECREF(traceback);
    Py_XDECREF(trace);
    Py_XDECREF(value);
    Py_DECREF(type);
    return text;
}

/* The bridge's error shape, from a message, built with json.dumps so it's always valid JSON. */
static char *internal_error(const char *message) {
    char *result = NULL;
    PyObject *json = PyImport_ImportModule("json");
    PyObject *payload = json == NULL ? NULL : Py_BuildValue("{s:O,s:{s:s,s:s}}", "ok", Py_False, "error", "type", "internal", "message", message);
    PyObject *text = payload == NULL ? NULL : PyObject_CallMethod(json, "dumps", "O", payload);
    const char *utf8 = text == NULL ? NULL : PyUnicode_AsUTF8(text);
    result = copy_text(utf8 != NULL ? utf8 : "{\"ok\": false, \"error\": {\"type\": \"internal\", \"message\": \"Python error\"}}");
    PyErr_Clear();
    Py_XDECREF(text);
    Py_XDECREF(payload);
    Py_XDECREF(json);
    return result;
}

static PyObject *progress_call(PyObject *self, PyObject *args) {
    long done, total;
    if (!PyArg_ParseTuple(args, "ll", &done, &total)) {
        return NULL;
    }
    progress_target *target = PyCapsule_GetPointer(self, "ap_progress");
    if (target == NULL) {
        return NULL;
    }
    Py_BEGIN_ALLOW_THREADS
    target->fn(target->context, done, total);
    Py_END_ALLOW_THREADS
    Py_RETURN_NONE;
}

static PyMethodDef progress_method = {"onProgress", progress_call, METH_VARARGS, NULL};

static void progress_capsule_free(PyObject *capsule) {
    free(PyCapsule_GetPointer(capsule, "ap_progress"));
}

/* An object with an onProgress method, which is what bridge.ingest takes. */
static PyObject *progress_object(ap_progress_fn fn, void *context) {
    progress_target *target = malloc(sizeof(progress_target));
    if (target == NULL) {
        return PyErr_NoMemory();
    }
    target->fn = fn;
    target->context = context;
    PyObject *capsule = PyCapsule_New(target, "ap_progress", progress_capsule_free);
    if (capsule == NULL) {
        free(target);
        return NULL;
    }
    PyObject *method = PyCFunction_New(&progress_method, capsule);
    Py_DECREF(capsule);
    if (method == NULL) {
        return NULL;
    }
    PyObject *empty = PyTuple_New(0);
    PyObject *fields = Py_BuildValue("{s:O}", "onProgress", method);
    PyObject *object = (empty == NULL || fields == NULL) ? NULL : PyObject_Call(simple_namespace, empty, fields);
    Py_XDECREF(fields);
    Py_XDECREF(empty);
    Py_DECREF(method);
    return object;
}

static int import_everything(const char *app_path) {
    PyObject *sys_path = PySys_GetObject("path"); /* borrowed */
    PyObject *path = PyUnicode_FromString(app_path);
    if (sys_path == NULL || path == NULL || PyList_Insert(sys_path, 0, path) != 0) {
        Py_XDECREF(path);
        return -1;
    }
    Py_DECREF(path);

    PyObject *json = PyImport_ImportModule("json");
    PyObject *types = PyImport_ImportModule("types");
    if (json == NULL || types == NULL) {
        Py_XDECREF(json);
        Py_XDECREF(types);
        return -1;
    }
    json_loads = PyObject_GetAttrString(json, "loads");
    simple_namespace = PyObject_GetAttrString(types, "SimpleNamespace");
    Py_DECREF(json);
    Py_DECREF(types);
    bridge_module = PyImport_ImportModule("audiopapers_core.bridge");
    return (json_loads != NULL && simple_namespace != NULL && bridge_module != NULL) ? 0 : -1;
}

int ap_python_start(const char *home, const char *app_path, const char *pycache_prefix, char **error) {
    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;

    if (home != NULL) {
        PyPreConfig_InitIsolatedConfig(&preconfig);
        PyConfig_InitIsolatedConfig(&config);
    } else {
        PyPreConfig_InitPythonConfig(&preconfig);
        PyConfig_InitPythonConfig(&config);
    }
    preconfig.utf8_mode = 1;
    config.buffered_stdio = 0;
    config.install_signal_handlers = 0;
    config.write_bytecode = pycache_prefix != NULL;

    status = Py_PreInitialize(&preconfig);
    if (!PyStatus_Exception(status) && home != NULL) {
        status = PyConfig_SetBytesString(&config, &config.home, home);
    }
    if (!PyStatus_Exception(status) && pycache_prefix != NULL) {
        status = PyConfig_SetBytesString(&config, &config.pycache_prefix, pycache_prefix);
    }
    if (!PyStatus_Exception(status)) {
        status = Py_InitializeFromConfig(&config);
    }
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) {
        *error = copy_text(status.err_msg != NULL ? status.err_msg : "Couldn't start Python");
        return -1;
    }

    if (import_everything(app_path) != 0) {
        *error = exception_text();
        PyEval_SaveThread();
        return -1;
    }
    /* Let go of the interpreter: calls take it as they need it, from any thread. */
    PyEval_SaveThread();
    return 0;
}

char *ap_python_call(const char *function, const char *args_json, const char *kwargs_json,
                     ap_progress_fn progress, void *context) {
    char *output = NULL;
    PyGILState_STATE gil = PyGILState_Ensure();

    PyObject *args_list = NULL, *args = NULL, *kwargs = NULL, *callable = NULL, *result = NULL;
    args_list = PyObject_CallFunction(json_loads, "s", args_json);
    args = args_list == NULL ? NULL : PySequence_Tuple(args_list);
    if (args == NULL) {
        goto failed;
    }
    kwargs = kwargs_json != NULL ? PyObject_CallFunction(json_loads, "s", kwargs_json) : PyDict_New();
    if (kwargs == NULL) {
        goto failed;
    }
    if (progress != NULL) {
        PyObject *object = progress_object(progress, context);
        if (object == NULL || PyDict_SetItemString(kwargs, "progress", object) != 0) {
            Py_XDECREF(object);
            goto failed;
        }
        Py_DECREF(object);
    }
    callable = PyObject_GetAttrString(bridge_module, function);
    result = callable == NULL ? NULL : PyObject_Call(callable, args, kwargs);
    if (result == NULL) {
        goto failed;
    }
    const char *utf8 = PyUnicode_AsUTF8(result);
    if (utf8 == NULL) {
        goto failed;
    }
    output = copy_text(utf8);
    goto done;

failed: {
        char *message = exception_text();
        output = internal_error(message);
        free(message);
    }

done:
    Py_XDECREF(result);
    Py_XDECREF(callable);
    Py_XDECREF(kwargs);
    Py_XDECREF(args);
    Py_XDECREF(args_list);
    PyGILState_Release(gil);
    return output;
}

void ap_python_free(char *text) {
    free(text);
}
